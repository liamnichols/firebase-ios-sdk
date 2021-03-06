/*
 * Copyright 2018 Google
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

#import "GoogleDataTransport/GDTCORLibrary/Private/GDTCORFlatFileStorage.h"

#import "GoogleDataTransport/GDTCORLibrary/Public/GDTCORAssert.h"
#import "GoogleDataTransport/GDTCORLibrary/Public/GDTCORConsoleLogger.h"
#import "GoogleDataTransport/GDTCORLibrary/Public/GDTCOREvent.h"
#import "GoogleDataTransport/GDTCORLibrary/Public/GDTCORLifecycle.h"
#import "GoogleDataTransport/GDTCORLibrary/Public/GDTCORPlatform.h"
#import "GoogleDataTransport/GDTCORLibrary/Public/GDTCORStorageEventSelector.h"

#import "GoogleDataTransport/GDTCORLibrary/Private/GDTCOREvent_Private.h"
#import "GoogleDataTransport/GDTCORLibrary/Private/GDTCORRegistrar_Private.h"
#import "GoogleDataTransport/GDTCORLibrary/Private/GDTCORUploadCoordinator.h"

/** A library data key this class uses to track batchIDs. */
static NSString *const gBatchIDCounterKey = @"GDTCORFlatFileStorageBatchIDCounter";

/** The separator used between metadata elements in filenames. */
static NSString *const kMetadataSeparator = @"-";

NSString *const kGDTCOREventComponentsEventIDKey = @"GDTCOREventComponentsEventIDKey";

NSString *const kGDTCOREventComponentsQoSTierKey = @"GDTCOREventComponentsQoSTierKey";

NSString *const kGDTCOREventComponentsMappingIDKey = @"GDTCOREventComponentsMappingIDKey";

NSString *const kGDTCOREventComponentsExpirationKey = @"GDTCOREventComponentsExpirationKey";

NSString *const kGDTCORBatchComponentsTargetKey = @"GDTCORBatchComponentsTargetKey";

NSString *const kGDTCORBatchComponentsBatchIDKey = @"GDTCORBatchComponentsBatchIDKey";

NSString *const kGDTCORBatchComponentsExpirationKey = @"GDTCORBatchComponentsExpirationKey";

@implementation GDTCORFlatFileStorage

+ (void)load {
#if !NDEBUG
  [[GDTCORRegistrar sharedInstance] registerStorage:[self sharedInstance] target:kGDTCORTargetTest];
#endif  // !NDEBUG
  [[GDTCORRegistrar sharedInstance] registerStorage:[self sharedInstance] target:kGDTCORTargetCCT];
  [[GDTCORRegistrar sharedInstance] registerStorage:[self sharedInstance] target:kGDTCORTargetFLL];
  [[GDTCORRegistrar sharedInstance] registerStorage:[self sharedInstance] target:kGDTCORTargetCSH];

  // Sets a global translation mapping to decode GDTCORStoredEvent objects encoded as instances of
  // GDTCOREvent instead. Then we do the same thing with GDTCORStorage. This must be done in load
  // because there are no direct references to this class and the NSCoding methods won't be called
  // unless the class name is mapped early.
  [NSKeyedUnarchiver setClass:[GDTCOREvent class] forClassName:@"GDTCORStoredEvent"];
  [NSKeyedUnarchiver setClass:[GDTCORFlatFileStorage class] forClassName:@"GDTCORStorage"];
}

+ (instancetype)sharedInstance {
  static GDTCORFlatFileStorage *sharedStorage;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedStorage = [[GDTCORFlatFileStorage alloc] init];
  });
  return sharedStorage;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _storageQueue =
        dispatch_queue_create("com.google.GDTCORFlatFileStorage", DISPATCH_QUEUE_SERIAL);
    _uploadCoordinator = [GDTCORUploadCoordinator sharedInstance];
  }
  return self;
}

#pragma mark - GDTCORStorageProtocol

- (void)storeEvent:(GDTCOREvent *)event
        onComplete:(void (^_Nullable)(BOOL wasWritten, NSError *_Nullable error))completion {
  GDTCORLogDebug(@"Saving event: %@", event);
  if (event == nil || event.serializedDataObjectBytes == nil) {
    GDTCORLogDebug(@"%@", @"The event was nil, so it was not saved.");
    if (completion) {
      completion(NO, [NSError errorWithDomain:NSInternalInconsistencyException
                                         code:-1
                                     userInfo:nil]);
    }
    return;
  }
  if (!completion) {
    completion = ^(BOOL wasWritten, NSError *_Nullable error) {
      GDTCORLogDebug(@"event %@ stored. success:%@ error:%@", event, wasWritten ? @"YES" : @"NO",
                     error);
    };
  }

  __block GDTCORBackgroundIdentifier bgID = GDTCORBackgroundIdentifierInvalid;
  bgID = [[GDTCORApplication sharedApplication]
      beginBackgroundTaskWithName:@"GDTStorage"
                expirationHandler:^{
                  // End the background task if it's still valid.
                  [[GDTCORApplication sharedApplication] endBackgroundTask:bgID];
                  bgID = GDTCORBackgroundIdentifierInvalid;
                }];

  dispatch_async(_storageQueue, ^{
    // Check that a backend implementation is available for this target.
    GDTCORTarget target = event.target;
    NSString *filePath = [GDTCORFlatFileStorage pathForTarget:target
                                                      eventID:event.eventID
                                                      qosTier:@(event.qosTier)
                                               expirationDate:event.expirationDate
                                                    mappingID:event.mappingID];
    NSError *error;
    GDTCOREncodeArchive(event, filePath, &error);
    if (error) {
      completion(NO, error);
      return;
    } else {
      completion(YES, nil);
    }

    // Check the QoS, if it's high priority, notify the target that it has a high priority event.
    if (event.qosTier == GDTCOREventQoSFast) {
      [self.uploadCoordinator forceUploadForTarget:target];
    }

    // Cancel or end the associated background task if it's still valid.
    [[GDTCORApplication sharedApplication] endBackgroundTask:bgID];
    bgID = GDTCORBackgroundIdentifierInvalid;
  });
}

- (void)batchWithEventSelector:(nonnull GDTCORStorageEventSelector *)eventSelector
               batchExpiration:(nonnull NSDate *)expiration
                    onComplete:
                        (nonnull void (^)(NSNumber *_Nullable batchID,
                                          NSSet<GDTCOREvent *> *_Nullable events))onComplete {
  dispatch_queue_t queue = _storageQueue;
  void (^onPathsForTargetComplete)(NSNumber *, NSSet<NSString *> *_Nonnull) = ^(
      NSNumber *batchID, NSSet<NSString *> *_Nonnull paths) {
    dispatch_async(queue, ^{
      NSMutableSet<GDTCOREvent *> *events = [[NSMutableSet alloc] init];
      for (NSString *eventPath in paths) {
        NSError *error;
        GDTCOREvent *event =
            (GDTCOREvent *)GDTCORDecodeArchive([GDTCOREvent class], eventPath, nil, &error);
        if (event == nil || error) {
          GDTCORLogDebug(@"Error deserializing event: %@", error);
          [[NSFileManager defaultManager] removeItemAtPath:eventPath error:nil];
          continue;
        } else {
          NSString *fileName = [eventPath lastPathComponent];
          NSString *batchPath =
              [GDTCORFlatFileStorage batchPathForTarget:eventSelector.selectedTarget
                                                batchID:batchID
                                         expirationDate:expiration];
          [[NSFileManager defaultManager] createDirectoryAtPath:batchPath
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:nil];
          NSString *destinationPath = [batchPath stringByAppendingPathComponent:fileName];
          error = nil;
          [[NSFileManager defaultManager] moveItemAtPath:eventPath
                                                  toPath:destinationPath
                                                   error:&error];
          if (error) {
            GDTCORLogDebug(@"An event file wasn't moveable into the batch directory: %@", error);
          }
          [events addObject:event];
        }
      }
      if (onComplete) {
        onComplete(batchID, events);
      }
    });
  };

  void (^onBatchIDFetchComplete)(NSNumber *) = ^(NSNumber *batchID) {
    dispatch_async(queue, ^{
      if (batchID == nil) {
        if (onComplete) {
          onComplete(nil, nil);
          return;
        }
      }
      [self pathsForTarget:eventSelector.selectedTarget
                  eventIDs:eventSelector.selectedEventIDs
                  qosTiers:eventSelector.selectedQosTiers
                mappingIDs:eventSelector.selectedMappingIDs
                onComplete:^(NSSet<NSString *> *_Nonnull paths) {
                  onPathsForTargetComplete(batchID, paths);
                }];
    });
  };

  [self nextBatchID:^(NSNumber *_Nullable batchID) {
    if (batchID == nil) {
      if (onComplete) {
        onComplete(nil, nil);
      }
    } else {
      onBatchIDFetchComplete(batchID);
    }
  }];
}

- (void)removeBatchWithID:(nonnull NSNumber *)batchID
             deleteEvents:(BOOL)deleteEvents
               onComplete:(void (^_Nullable)(void))onComplete {
  dispatch_async(_storageQueue, ^{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error;
    NSArray<NSString *> *batches =
        [fileManager contentsOfDirectoryAtPath:[GDTCORFlatFileStorage batchDataStoragePath]
                                         error:&error];
    if (error) {
      if (onComplete) {
        onComplete();
      }
      return;
    }
    for (NSString *path in batches) {
      NSDictionary<NSString *, id> *components = [self batchComponentsFromFilename:path];
      NSNumber *target = components[kGDTCORBatchComponentsTargetKey];
      NSNumber *batchIDToRemove = components[kGDTCORBatchComponentsBatchIDKey];
      if ([batchIDToRemove isEqual:batchID]) {
        if (deleteEvents) {
          NSString *deletionPath =
              [[GDTCORFlatFileStorage batchDataStoragePath] stringByAppendingPathComponent:path];
          [fileManager removeItemAtPath:deletionPath error:nil];
        } else {
          NSString *destinationPath = [[GDTCORFlatFileStorage eventDataStoragePath]
              stringByAppendingPathComponent:target.stringValue];
          [fileManager moveItemAtPath:path toPath:destinationPath error:&error];
          if (error) {
            GDTCORLogDebug(@"Error encountered whilst moving events back: %@", error);
          }
        }
      }
    }
    if (onComplete) {
      onComplete();
    }
  });
}

- (void)batchIDsForTarget:(GDTCORTarget)target
               onComplete:(nonnull void (^)(NSSet<NSNumber *> *_Nullable))onComplete {
  dispatch_async(_storageQueue, ^{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error;
    NSArray<NSString *> *batchPaths =
        [fileManager contentsOfDirectoryAtPath:[GDTCORFlatFileStorage batchDataStoragePath]
                                         error:&error];
    if (error || batchPaths.count == 0) {
      if (onComplete) {
        onComplete(nil);
      }
      return;
    }
    NSMutableSet<NSNumber *> *batchIDs = [[NSMutableSet alloc] init];
    for (NSString *path in batchPaths) {
      NSDictionary<NSString *, id> *components = [self batchComponentsFromFilename:path];
      NSNumber *targetNumber = components[kGDTCORBatchComponentsTargetKey];
      NSNumber *batchID = components[kGDTCORBatchComponentsBatchIDKey];
      if (targetNumber.intValue == target) {
        [batchIDs addObject:batchID];
      }
    }
    if (onComplete) {
      onComplete(batchIDs);
    }
  });
}

- (void)libraryDataForKey:(nonnull NSString *)key
          onFetchComplete:(nonnull void (^)(NSData *_Nullable, NSError *_Nullable))onFetchComplete
              setNewValue:(NSData *_Nullable (^_Nullable)(void))setValueBlock {
  dispatch_async(_storageQueue, ^{
    NSString *dataPath = [[[self class] libraryDataStoragePath] stringByAppendingPathComponent:key];
    NSError *error;
    NSData *data = [NSData dataWithContentsOfFile:dataPath options:0 error:&error];
    if (onFetchComplete) {
      onFetchComplete(data, error);
    }
    if (setValueBlock) {
      NSData *newValue = setValueBlock();
      // The -isKindOfClass check is necessary because without an explicit 'return nil' in the block
      // the implicit return value will be the block itself. The compiler doesn't detect this.
      if (newValue != nil && [newValue isKindOfClass:[NSData class]] && newValue.length) {
        NSError *newValueError;
        [newValue writeToFile:dataPath options:NSDataWritingAtomic error:&newValueError];
        if (newValueError) {
          GDTCORLogDebug(@"Error writing new value in libraryDataForKey: %@", newValueError);
        }
      }
    }
  });
}

- (void)storeLibraryData:(NSData *)data
                  forKey:(nonnull NSString *)key
              onComplete:(nullable void (^)(NSError *_Nullable error))onComplete {
  if (!data || data.length <= 0) {
    if (onComplete) {
      onComplete([NSError errorWithDomain:NSInternalInconsistencyException code:-1 userInfo:nil]);
    }
    return;
  }
  dispatch_async(_storageQueue, ^{
    NSError *error;
    NSString *dataPath = [[[self class] libraryDataStoragePath] stringByAppendingPathComponent:key];
    [data writeToFile:dataPath options:NSDataWritingAtomic error:&error];
    if (onComplete) {
      onComplete(error);
    }
  });
}

- (void)removeLibraryDataForKey:(nonnull NSString *)key
                     onComplete:(nonnull void (^)(NSError *_Nullable error))onComplete {
  dispatch_async(_storageQueue, ^{
    NSError *error;
    NSString *dataPath = [[[self class] libraryDataStoragePath] stringByAppendingPathComponent:key];
    if ([[NSFileManager defaultManager] fileExistsAtPath:dataPath]) {
      [[NSFileManager defaultManager] removeItemAtPath:dataPath error:&error];
      if (onComplete) {
        onComplete(error);
      }
    }
  });
}

- (void)hasEventsForTarget:(GDTCORTarget)target onComplete:(void (^)(BOOL hasEvents))onComplete {
  dispatch_async(_storageQueue, ^{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *targetPath = [NSString
        stringWithFormat:@"%@/%ld", [GDTCORFlatFileStorage eventDataStoragePath], (long)target];
    [fileManager createDirectoryAtPath:targetPath
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];
    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtPath:targetPath];
    BOOL hasEventAtLeastOneEvent = [enumerator nextObject] != nil;
    if (onComplete) {
      onComplete(hasEventAtLeastOneEvent);
    }
  });
}

- (void)checkForExpirations {
  dispatch_async(_storageQueue, ^{
    NSMutableSet<NSString *> *pathsToDelete = [[NSMutableSet alloc] init];
    GDTCORLogDebug(@"%@", @"Checking for expired events and batches");
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *eventDataPath = [GDTCORFlatFileStorage eventDataStoragePath];
    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtPath:eventDataPath];
    NSString *path;
    while ((path = [enumerator nextObject])) {
      NSString *fileName = [path lastPathComponent];
      NSDictionary<NSString *, id> *eventComponents = [self eventComponentsFromFilename:fileName];
      NSDate *expirationDate = eventComponents[kGDTCOREventComponentsExpirationKey];
      if (expirationDate != nil && expirationDate.timeIntervalSince1970 < now) {
        [pathsToDelete addObject:[eventDataPath stringByAppendingPathComponent:path]];
      }
    }

    NSString *batchDataPath = [GDTCORFlatFileStorage batchDataStoragePath];
    NSArray<NSString *> *batchDataPaths = [fileManager contentsOfDirectoryAtPath:batchDataPath
                                                                           error:nil];
    for (NSString *path in batchDataPaths) {
      NSString *fileName = [path lastPathComponent];
      NSDictionary<NSString *, id> *batchComponents = [self batchComponentsFromFilename:fileName];
      NSDate *expirationDate = batchComponents[kGDTCORBatchComponentsExpirationKey];
      if (expirationDate != nil && expirationDate.timeIntervalSince1970 < now) {
        [pathsToDelete addObject:[batchDataPath stringByAppendingPathComponent:path]];
      }
    }

    for (NSString *path in pathsToDelete) {
      NSError *error;
      [fileManager removeItemAtPath:path error:&error];
      if (error != nil) {
        GDTCORLogDebug(@"There was an error deleting an expired item: %@", error);
      } else {
        GDTCORLogDebug(@"Item deleted because it expired: %@", path);
      }
    }
  });
}

- (void)storageSizeWithCallback:(void (^)(uint64_t storageSize))onComplete {
  dispatch_async(_storageQueue, ^{
    unsigned long long totalBytes = 0;
    NSString *eventDataPath = [GDTCORFlatFileStorage eventDataStoragePath];
    NSString *libraryDataPath = [GDTCORFlatFileStorage libraryDataStoragePath];
    NSString *batchDataPath = [GDTCORFlatFileStorage batchDataStoragePath];
    NSDirectoryEnumerator *enumerator =
        [[NSFileManager defaultManager] enumeratorAtPath:eventDataPath];
    while ([enumerator nextObject]) {
      NSFileAttributeType fileType = enumerator.fileAttributes[NSFileType];
      if ([fileType isEqual:NSFileTypeRegular]) {
        NSNumber *fileSize = enumerator.fileAttributes[NSFileSize];
        totalBytes += fileSize.unsignedLongLongValue;
      }
    }
    enumerator = [[NSFileManager defaultManager] enumeratorAtPath:libraryDataPath];
    while ([enumerator nextObject]) {
      NSFileAttributeType fileType = enumerator.fileAttributes[NSFileType];
      if ([fileType isEqual:NSFileTypeRegular]) {
        NSNumber *fileSize = enumerator.fileAttributes[NSFileSize];
        totalBytes += fileSize.unsignedLongLongValue;
      }
    }
    enumerator = [[NSFileManager defaultManager] enumeratorAtPath:batchDataPath];
    while ([enumerator nextObject]) {
      NSFileAttributeType fileType = enumerator.fileAttributes[NSFileType];
      if ([fileType isEqual:NSFileTypeRegular]) {
        NSNumber *fileSize = enumerator.fileAttributes[NSFileSize];
        totalBytes += fileSize.unsignedLongLongValue;
      }
    }
    if (onComplete) {
      onComplete(totalBytes);
    }
  });
}

#pragma mark - Private helper methods

+ (NSString *)eventDataStoragePath {
  static NSString *eventDataPath;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    eventDataPath = [NSString stringWithFormat:@"%@/%@/gdt_event_data", GDTCORRootDirectory().path,
                                               NSStringFromClass([self class])];
  });
  NSError *error;
  [[NSFileManager defaultManager] createDirectoryAtPath:eventDataPath
                            withIntermediateDirectories:YES
                                             attributes:0
                                                  error:&error];
  GDTCORAssert(error == nil, @"Creating the library data path failed: %@", error);
  return eventDataPath;
}

+ (NSString *)batchDataStoragePath {
  static NSString *batchDataPath;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    batchDataPath = [NSString stringWithFormat:@"%@/%@/gdt_batch_data", GDTCORRootDirectory().path,
                                               NSStringFromClass([self class])];
  });
  NSError *error;
  [[NSFileManager defaultManager] createDirectoryAtPath:batchDataPath
                            withIntermediateDirectories:YES
                                             attributes:0
                                                  error:&error];
  GDTCORAssert(error == nil, @"Creating the batch data path failed: %@", error);
  return batchDataPath;
}

+ (NSString *)libraryDataStoragePath {
  static NSString *libraryDataPath;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    libraryDataPath =
        [NSString stringWithFormat:@"%@/%@/gdt_library_data", GDTCORRootDirectory().path,
                                   NSStringFromClass([self class])];
  });
  NSError *error;
  [[NSFileManager defaultManager] createDirectoryAtPath:libraryDataPath
                            withIntermediateDirectories:YES
                                             attributes:0
                                                  error:&error];
  GDTCORAssert(error == nil, @"Creating the library data path failed: %@", error);
  return libraryDataPath;
}

+ (NSString *)batchPathForTarget:(GDTCORTarget)target
                         batchID:(NSNumber *)batchID
                  expirationDate:(NSDate *)expirationDate {
  return
      [NSString stringWithFormat:@"%@/%ld%@%@%@%llu", [GDTCORFlatFileStorage batchDataStoragePath],
                                 (long)target, kMetadataSeparator, batchID, kMetadataSeparator,
                                 ((uint64_t)expirationDate.timeIntervalSince1970)];
}

+ (NSString *)pathForTarget:(GDTCORTarget)target
                    eventID:(NSString *)eventID
                    qosTier:(NSNumber *)qosTier
             expirationDate:(NSDate *)expirationDate
                  mappingID:(NSString *)mappingID {
  NSMutableCharacterSet *allowedChars = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
  [allowedChars addCharactersInString:kMetadataSeparator];
  mappingID = [mappingID stringByAddingPercentEncodingWithAllowedCharacters:allowedChars];
  return [NSString stringWithFormat:@"%@/%ld/%@%@%@%@%llu%@%@",
                                    [GDTCORFlatFileStorage eventDataStoragePath], (long)target,
                                    eventID, kMetadataSeparator, qosTier, kMetadataSeparator,
                                    ((uint64_t)expirationDate.timeIntervalSince1970),
                                    kMetadataSeparator, mappingID];
}

- (void)pathsForTarget:(GDTCORTarget)target
              eventIDs:(nullable NSSet<NSString *> *)eventIDs
              qosTiers:(nullable NSSet<NSNumber *> *)qosTiers
            mappingIDs:(nullable NSSet<NSString *> *)mappingIDs
            onComplete:(void (^)(NSSet<NSString *> *paths))onComplete {
  void (^completion)(NSSet<NSString *> *) = onComplete == nil ? ^(NSSet<NSString *> *paths){} : onComplete;
  dispatch_async(_storageQueue, ^{
    NSMutableSet<NSString *> *paths = [[NSMutableSet alloc] init];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *targetPath = [NSString
        stringWithFormat:@"%@/%ld", [GDTCORFlatFileStorage eventDataStoragePath], (long)target];
    [fileManager createDirectoryAtPath:targetPath
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];
    NSError *error;
    NSArray<NSString *> *dirPaths = [fileManager contentsOfDirectoryAtPath:targetPath error:&error];
    if (error) {
      GDTCORLogDebug(@"There was an error reading the contents of the target path: %@", error);
      completion(paths);
      return;
    }
    BOOL checkingIDs = eventIDs.count > 0;
    BOOL checkingQosTiers = qosTiers.count > 0;
    BOOL checkingMappingIDs = mappingIDs.count > 0;
    BOOL checkingAnything = checkingIDs == NO && checkingQosTiers == NO && checkingMappingIDs == NO;
    for (NSString *path in dirPaths) {
      // Skip hidden files that are created as part of atomic file creation.
      if ([path hasPrefix:@"."]) {
        continue;
      }
      NSString *filePath = [targetPath stringByAppendingPathComponent:path];
      if (checkingAnything) {
        [paths addObject:filePath];
        continue;
      }
      NSString *filename = [path lastPathComponent];
      NSDictionary<NSString *, id> *eventComponents = [self eventComponentsFromFilename:filename];
      if (!eventComponents) {
        GDTCORLogDebug(@"There was an error reading the filename components: %@", eventComponents);
        continue;
      }
      NSString *eventID = eventComponents[kGDTCOREventComponentsEventIDKey];
      NSNumber *qosTier = eventComponents[kGDTCOREventComponentsQoSTierKey];
      NSString *mappingID = eventComponents[kGDTCOREventComponentsMappingIDKey];

      NSNumber *eventIDMatch = checkingIDs ? @([eventIDs containsObject:eventID]) : nil;
      NSNumber *qosTierMatch = checkingQosTiers ? @([qosTiers containsObject:qosTier]) : nil;
      NSNumber *mappingIDMatch =
          checkingMappingIDs
              ? @([mappingIDs containsObject:[mappingID stringByRemovingPercentEncoding]])
              : nil;
      if ((eventIDMatch == nil || eventIDMatch.boolValue) &&
          (qosTierMatch == nil || qosTierMatch.boolValue) &&
          (mappingIDMatch == nil || mappingIDMatch.boolValue)) {
        [paths addObject:filePath];
      }
    }
    completion(paths);
  });
}

- (void)nextBatchID:(void (^)(NSNumber *_Nullable batchID))nextBatchID {
  __block int32_t lastBatchID = -1;
  [self libraryDataForKey:gBatchIDCounterKey
      onFetchComplete:^(NSData *_Nullable data, NSError *_Nullable getValueError) {
        if (!getValueError) {
          [data getBytes:(void *)&lastBatchID length:sizeof(int32_t)];
        }
        if (data == nil) {
          lastBatchID = 0;
        }
        if (nextBatchID) {
          nextBatchID(@(lastBatchID));
        }
      }
      setNewValue:^NSData *_Nullable(void) {
        if (lastBatchID != -1) {
          int32_t incrementedValue = lastBatchID + 1;
          return [NSData dataWithBytes:&incrementedValue length:sizeof(int32_t)];
        }
        return nil;
      }];
}

- (nullable NSDictionary<NSString *, id> *)eventComponentsFromFilename:(NSString *)fileName {
  NSArray<NSString *> *components = [fileName componentsSeparatedByString:kMetadataSeparator];
  if (components.count >= 4) {
    NSString *eventID = components[0];
    NSNumber *qosTier = @(components[1].integerValue);
    NSDate *expirationDate = [NSDate dateWithTimeIntervalSince1970:components[2].longLongValue];
    NSString *mappingID = [[components subarrayWithRange:NSMakeRange(3, components.count - 3)]
        componentsJoinedByString:kMetadataSeparator];
    if (eventID == nil || qosTier == nil || mappingID == nil || expirationDate == nil) {
      GDTCORLogDebug(@"There was an error parsing the event filename components: %@", components);
      return nil;
    }
    return @{
      kGDTCOREventComponentsEventIDKey : eventID,
      kGDTCOREventComponentsQoSTierKey : qosTier,
      kGDTCOREventComponentsExpirationKey : expirationDate,
      kGDTCOREventComponentsMappingIDKey : mappingID
    };
  }
  GDTCORLogDebug(@"The event filename could not be split: %@", fileName);
  return nil;
}

- (nullable NSDictionary<NSString *, id> *)batchComponentsFromFilename:(NSString *)fileName {
  NSArray<NSString *> *components = [fileName componentsSeparatedByString:kMetadataSeparator];
  if (components.count == 3) {
    NSNumber *target = @(components[0].integerValue);
    NSNumber *batchID = @(components[1].integerValue);
    NSDate *expirationDate = [NSDate dateWithTimeIntervalSince1970:components[2].doubleValue];
    if (target == nil || batchID == nil || expirationDate == nil) {
      GDTCORLogDebug(@"There was an error parsing the batch filename components: %@", components);
      return nil;
    }
    return @{
      kGDTCORBatchComponentsTargetKey : target,
      kGDTCORBatchComponentsBatchIDKey : batchID,
      kGDTCORBatchComponentsExpirationKey : expirationDate
    };
  }
  GDTCORLogDebug(@"The batch filename could not be split: %@", fileName);
  return nil;
}

#pragma mark - GDTCORLifecycleProtocol

- (void)appWillBackground:(GDTCORApplication *)app {
  dispatch_async(_storageQueue, ^{
    // Immediately request a background task to run until the end of the current queue of work,
    // and cancel it once the work is done.
    __block GDTCORBackgroundIdentifier bgID =
        [app beginBackgroundTaskWithName:@"GDTStorage"
                       expirationHandler:^{
                         [app endBackgroundTask:bgID];
                         bgID = GDTCORBackgroundIdentifierInvalid;
                       }];
    // End the background task if it's still valid.
    [app endBackgroundTask:bgID];
    bgID = GDTCORBackgroundIdentifierInvalid;
  });
}

- (void)appWillTerminate:(GDTCORApplication *)application {
  dispatch_sync(_storageQueue, ^{
                });
}

@end
