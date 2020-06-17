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

#import "FIRMessagingTokenDeleteOperation.h"

#import "FIRMessagingCheckinPreferences.h"
#import "FIRMessagingDefines.h"
#import "FIRMessagingLogger.h"
#import "FIRMessagingTokenOperation+Private.h"
#import "FIRMessagingURLQueryItem.h"
#import "FIRMessagingUtilities.h"
#import "NSError+FIRMessaging.h"

@implementation FIRMessagingTokenDeleteOperation

- (instancetype)initWithAuthorizedEntity:(NSString *)authorizedEntity
                                   scope:(NSString *)scope
                      checkinPreferences:(FIRMessagingCheckinPreferences *)checkinPreferences
                              instanceID:(NSString *)instanceID
                                  action:(FIRMessagingTokenAction)action {
  self = [super initWithAction:action
           forAuthorizedEntity:authorizedEntity
                         scope:scope
                       options:nil
            checkinPreferences:checkinPreferences
                    instanceID:instanceID];
  if (self) {
  }
  return self;
}

- (void)performTokenOperation {
  NSMutableURLRequest *request = [self tokenRequest];

  // Build form-encoded body
  NSString *deviceAuthID = self.checkinPreferences.deviceID;
  NSMutableArray<FIRMessagingURLQueryItem *> *queryItems =
      [FIRMessagingTokenOperation standardQueryItemsWithDeviceID:deviceAuthID scope:self.scope];
  [queryItems addObject:[FIRMessagingURLQueryItem queryItemWithName:@"delete" value:@"true"]];
  if (self.action == FIRMessagingTokenActionDeleteTokenAndIID) {
    [queryItems addObject:[FIRMessagingURLQueryItem queryItemWithName:@"iid-operation"
                                                                 value:@"delete"]];
  }
  if (self.authorizedEntity) {
    [queryItems addObject:[FIRMessagingURLQueryItem queryItemWithName:@"sender"
                                                                 value:self.authorizedEntity]];
  }
  // Typically we include our public key-signed url items, but in some cases (like deleting all FCM
  // tokens), we don't.
  if (self.instanceID.length > 0) {
    [queryItems addObjectsFromArray:[self queryItemsWithInstanceID:self.instanceID]];
  }

  NSString *content = FIRMessagingQueryFromQueryItems(queryItems);
  request.HTTPBody = [content dataUsingEncoding:NSUTF8StringEncoding];
  FIRMessagingLoggerDebug(kFIRMessagingMessageCodeTokenDeleteOperationFetchRequest,
                           @"Unregister request to %@ content: %@", FIRMessagingRegisterServer(),
                           content);

  FIRMessaging_WEAKIFY(self);
  void (^requestHandler)(NSData *, NSURLResponse *, NSError *) =
      ^(NSData *data, NSURLResponse *response, NSError *error) {
        FIRMessaging_STRONGIFY(self);
        [self handleResponseWithData:data response:response error:error];
      };

  // Test block
  if (self.testBlock) {
    self.testBlock(request, requestHandler);
    return;
  }

  NSURLSession *session = [FIRMessagingTokenOperation sharedURLSession];
  self.dataTask = [session dataTaskWithRequest:request completionHandler:requestHandler];
  [self.dataTask resume];
}

- (void)handleResponseWithData:(NSData *)data
                      response:(NSURLResponse *)response
                         error:(NSError *)error {
  if (error) {
    FIRMessagingLoggerDebug(kFIRMessagingMessageCodeTokenDeleteOperationRequestError,
                             @"Device unregister HTTP fetch error. Error code: %ld",
                             _FIRMessaging_L(error.code));
    [self finishWithResult:FIRMessagingTokenOperationError token:nil error:error];
    return;
  }

  NSString *dataResponse = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (dataResponse.length == 0) {
    NSError *error = [NSError errorWithFIRMessagingErrorCode:kFIRMessagingErrorCodeUnknown];
    [self finishWithResult:FIRMessagingTokenOperationError token:nil error:error];
    return;
  }

  if (![dataResponse hasPrefix:@"deleted="] && ![dataResponse hasPrefix:@"token="]) {
    FIRMessagingLoggerDebug(kFIRMessagingMessageCodeTokenDeleteOperationBadResponse,
                             @"Invalid unregister response %@", response);
    NSError *error = [NSError errorWithFIRMessagingErrorCode:kFIRMessagingErrorCodeUnknown];
    [self finishWithResult:FIRMessagingTokenOperationError token:nil error:error];
    return;
  }
  [self finishWithResult:FIRMessagingTokenOperationSucceeded token:nil error:nil];
}
@end