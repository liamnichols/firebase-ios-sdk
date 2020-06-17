/*
 * Copyright 2019 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FIRMessagingTokenOperation.h"

#import <FirebaseInstallations/FirebaseInstallations.h>

#import "FIRMessagingCheckinPreferences.h"
#import "FIRMessagingLogger.h"
#import "FIRMessagingURLQueryItem.h"
#import "FIRMessagingUtilities.h"
#import "NSError+FIRMessaging.h"

static const NSInteger kFIRMessagingPlatformVersionIOS = 2;

static NSString *const kFIRMessagingParamInstanceID = @"appid";
// Scope parameter that defines the service using the token
static NSString *const kFIRMessagingParamScope = @"X-scope";
// Defines the SDK version
static NSString *const kFIRMessagingParamFCMLibVersion = @"X-cliv";

@interface FIRMessagingTokenOperation () {
  BOOL _isFinished;
  BOOL _isExecuting;
}

@property(nonatomic, readwrite, strong) FIRMessagingCheckinPreferences *checkinPreferences;
@property(nonatomic, readwrite, strong) NSString *instanceID;

@property(atomic, strong) NSURLSessionDataTask *dataTask;
@property(readonly, strong)
    NSMutableArray<FIRMessagingTokenOperationCompletion> *completionHandlers;

@property(atomic, strong, nullable) NSString *FISAuthToken;

// For testing only
@property(nonatomic, readwrite, copy) FIRMessagingURLRequestTestBlock testBlock;

@end

@implementation FIRMessagingTokenOperation

+ (NSURLSession *)sharedURLSession {
  static NSURLSession *tokenOperationSharedSession;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForResource = 60.0f;  // 1 minute
    tokenOperationSharedSession = [NSURLSession sessionWithConfiguration:config];
    tokenOperationSharedSession.sessionDescription = @"com.google.iid.tokens.session";
  });
  return tokenOperationSharedSession;
}

- (instancetype)initWithAction:(FIRMessagingTokenAction)action
           forAuthorizedEntity:(NSString *)authorizedEntity
                         scope:(NSString *)scope
                       options:(NSDictionary<NSString *, NSString *> *)options
            checkinPreferences:(FIRMessagingCheckinPreferences *)checkinPreferences
                    instanceID:(NSString *)instanceID {
  self = [super init];
  if (self) {
    _action = action;
    _authorizedEntity = [authorizedEntity copy];
    _scope = [scope copy];
    _options = [options copy];
    _checkinPreferences = checkinPreferences;
    _instanceID = instanceID;
    _completionHandlers = [NSMutableArray array];

    _isExecuting = NO;
    _isFinished = NO;
  }
  return self;
}

- (void)dealloc {
  _testBlock = nil;
  _authorizedEntity = nil;
  _scope = nil;
  _options = nil;
  _checkinPreferences = nil;
  _instanceID = nil;
  [_completionHandlers removeAllObjects];
  _completionHandlers = nil;
}

- (void)addCompletionHandler:(FIRMessagingTokenOperationCompletion)handler {
  [self.completionHandlers addObject:handler];
}

- (BOOL)isAsynchronous {
  return YES;
}

- (BOOL)isExecuting {
  return _isExecuting;
}

- (void)setExecuting:(BOOL)executing {
  [self willChangeValueForKey:@"isExecuting"];
  _isExecuting = executing;
  [self didChangeValueForKey:@"isExecuting"];
}

- (BOOL)isFinished {
  return _isFinished;
}

- (void)setFinished:(BOOL)finished {
  [self willChangeValueForKey:@"isFinished"];
  _isFinished = finished;
  [self didChangeValueForKey:@"isFinished"];
}

- (void)start {
  if (self.isCancelled) {
    [self finishWithResult:FIRMessagingTokenOperationCancelled token:nil error:nil];
    return;
  }

  // Quickly validate whether or not the operation has all it needs to begin
  BOOL checkinfoAvailable = [self.checkinPreferences hasCheckinInfo];
  if (!checkinfoAvailable) {
    FIRMessagingErrorCode errorCode = kFIRMessagingErrorCodeRegistrarFailedToCheckIn;
    [self finishWithResult:FIRMessagingTokenOperationError
                     token:nil
                     error:[NSError errorWithFIRMessagingErrorCode:errorCode]];
    return;
  }

  [self setExecuting:YES];

  [[FIRInstallations installations]
      authTokenWithCompletion:^(FIRInstallationsAuthTokenResult *_Nullable tokenResult,
                                NSError *_Nullable error) {
        if (tokenResult.authToken.length > 0) {
          self.FISAuthToken = tokenResult.authToken;
          [self performTokenOperation];
        } else {
          [self finishWithResult:FIRMessagingTokenOperationError token:nil error:error];
        }
      }];
}

- (void)finishWithResult:(FIRMessagingTokenOperationResult)result
                   token:(nullable NSString *)token
                   error:(nullable NSError *)error {
  // Add a check to prevent this finish from being called more than once.
  if (self.isFinished) {
    return;
  }
  self.dataTask = nil;
  _result = result;
  // TODO(chliangGoogle): Call these in the main thread?
  for (FIRMessagingTokenOperationCompletion completionHandler in self.completionHandlers) {
    completionHandler(result, token, error);
  }

  [self setExecuting:NO];
  [self setFinished:YES];
}

- (void)cancel {
  [super cancel];
  [self.dataTask cancel];
  [self finishWithResult:FIRMessagingTokenOperationCancelled token:nil error:nil];
}

- (void)performTokenOperation {
}

- (NSMutableURLRequest *)tokenRequest {
  NSString *authHeader =
      [FIRMessagingTokenOperation HTTPAuthHeaderFromCheckin:self.checkinPreferences];
  return [[self class] requestWithAuthHeader:authHeader FISAuthToken:self.FISAuthToken];
}

#pragma mark - Request Construction
+ (NSMutableURLRequest *)requestWithAuthHeader:(NSString *)authHeaderString
                                  FISAuthToken:(NSString *)FISAuthToken {
  NSURL *url = [NSURL URLWithString:FIRMessagingRegisterServer()];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];

  // Add HTTP headers
  [request setValue:authHeaderString forHTTPHeaderField:@"Authorization"];
  [request setValue:FIRMessagingAppIdentifier() forHTTPHeaderField:@"app"];
  if (FISAuthToken) {
    [request setValue:FISAuthToken forHTTPHeaderField:@"x-goog-firebase-installations-auth"];
  }
  request.HTTPMethod = @"POST";
  return request;
}

+ (NSMutableArray<FIRMessagingURLQueryItem *> *)standardQueryItemsWithDeviceID:(NSString *)deviceID
                                                                          scope:(NSString *)scope {
  NSMutableArray<FIRMessagingURLQueryItem *> *queryItems = [NSMutableArray arrayWithCapacity:8];

  // E.g. X-osv=10.2.1
  NSString *systemVersion = FIRMessagingOperatingSystemVersion();
  [queryItems addObject:[FIRMessagingURLQueryItem queryItemWithName:@"X-osv" value:systemVersion]];
  // E.g. device=
  if (deviceID) {
    [queryItems addObject:[FIRMessagingURLQueryItem queryItemWithName:@"device" value:deviceID]];
  }
  // E.g. X-scope=fcm
  if (scope) {
    [queryItems addObject:[FIRMessagingURLQueryItem queryItemWithName:kFIRMessagingParamScope
                                                                 value:scope]];
  }
  // E.g. plat=2
  NSString *platform = [NSString stringWithFormat:@"%ld", (long)kFIRMessagingPlatformVersionIOS];
  [queryItems addObject:[FIRMessagingURLQueryItem queryItemWithName:@"plat" value:platform]];
  // E.g. app=com.myapp.foo
  NSString *appIdentifier = FIRMessagingAppIdentifier();
  [queryItems addObject:[FIRMessagingURLQueryItem queryItemWithName:@"app" value:appIdentifier]];
  // E.g. app_ver=1.5
  NSString *appVersion = FIRMessagingCurrentAppVersion();
  [queryItems addObject:[FIRMessagingURLQueryItem queryItemWithName:@"app_ver" value:appVersion]];
  // E.g. X-cliv=fiid-1.2.3
  NSString *fcmLibraryVersion =
      [NSString stringWithFormat:@"fiid-%@", FIRMessagingCurrentGCMVersion()];
  if (fcmLibraryVersion.length) {
    FIRMessagingURLQueryItem *gcmLibVersion =
        [FIRMessagingURLQueryItem queryItemWithName:kFIRMessagingParamFCMLibVersion
                                               value:fcmLibraryVersion];
    [queryItems addObject:gcmLibVersion];
  }

  return queryItems;
}

- (NSArray<FIRMessagingURLQueryItem *> *)queryItemsWithInstanceID:(NSString *)instanceID {
  return @[ [FIRMessagingURLQueryItem queryItemWithName:kFIRMessagingParamInstanceID
                                                   value:instanceID] ];
}

#pragma mark - HTTP Header

+ (NSString *)HTTPAuthHeaderFromCheckin:(FIRMessagingCheckinPreferences *)checkin {
  NSString *deviceID = checkin.deviceID;
  NSString *secret = checkin.secretToken;
  return [NSString stringWithFormat:@"AidLogin %@:%@", deviceID, secret];
}
@end