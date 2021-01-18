
#import "RNCloudFs.h"
#import <UIKit/UIKit.h>
#if __has_include(<React/RCTBridgeModule.h>)
  #import <React/RCTBridgeModule.h>
#else
  #import "RCTBridgeModule.h"
#endif
#import "RCTEventDispatcher.h"
#import "RCTUtils.h"
#import <AssetsLibrary/AssetsLibrary.h>
#import "RCTLog.h"

@interface RNCloudFsQueryCallback : NSObject
@property (nonatomic, weak) NSMetadataQuery *query;
@property (nonatomic, strong) void(^callback)(NSArray *);
@end

@implementation RNCloudFsQueryCallback
@end

@interface RNCloudFsFilesListQuery : NSObject
@property (nonatomic, strong) NSMetadataQuery *queryData;
@property (nonatomic, strong) NSMutableArray<RNCloudFsQueryCallback *> *queryCallbacks;
@property (nonatomic, strong) NSFileCoordinator *fileCoordinator;
@end

@implementation RNCloudFsFilesListQuery

- (instancetype)init {
    self = [super init];
    if (self) {
        self.queryCallbacks = [[NSMutableArray alloc] init];
        self.fileCoordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    }
    return self;
}

- (void)listFilesAtPath:(NSString *)path callback:(void(^)(NSArray *filesList))callback {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMetadataQuery *queryData = [[NSMetadataQuery alloc] init];
        [queryData setSearchScopes:[NSArray arrayWithObject:NSMetadataQueryUbiquitousDocumentsScope]];
        NSPredicate *pathPredicate1 = [NSPredicate predicateWithFormat: @"%K BEGINSWITH %@", NSMetadataItemPathKey, path];
        NSPredicate *pathPredicate2 = [NSPredicate predicateWithFormat: @"NOT (%K ENDSWITH %@)", NSMetadataItemPathKey, path];
        [queryData setPredicate:[NSCompoundPredicate andPredicateWithSubpredicates:@[pathPredicate1, pathPredicate2]]];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(queryDidFinishGathering:)
                                                     name:NSMetadataQueryDidFinishGatheringNotification
                                                   object:queryData];
        [queryData startQuery];
        self.queryData = queryData;
        RNCloudFsQueryCallback *queryCallback = [[RNCloudFsQueryCallback alloc] init];
        queryCallback.query = queryData;
        queryCallback.callback = callback;
        [self.queryCallbacks addObject:queryCallback];
    });
}

- (void)queryDidFinishGathering:(NSNotification *)notification {
    NSMetadataQuery *query = [notification object];
    [query disableUpdates];
    [query stopQuery];
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZZZ"];
    NSMutableArray *filesArray = [[NSMutableArray alloc] init];
    for (NSMetadataItem *item in [query results]) {
        NSURL *url = [item valueForAttribute:NSMetadataItemURLKey];
        if (!url) {
            continue;
        }
        NSString *fileName = [url.absoluteString lastPathComponent];
        NSError *error = nil;
        __block NSDictionary *attributes;
        [self.fileCoordinator coordinateReadingItemAtURL:url
                                                 options:NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly
                                                   error:&error
                                              byAccessor:^(NSURL * _Nonnull newURL) {
            NSError *error;
            attributes = [url promisedItemResourceValuesForKeys:@[NSURLContentModificationDateKey, NSURLFileSizeKey, NSURLUbiquitousItemIsDownloadedKey, NSURLIsDirectoryKey, NSURLIsRegularFileKey] error:&error];
        }];

        if (!attributes) {
            continue;
        }
        [filesArray addObject:@{
            @"path": url.path,
            @"name": fileName,
            @"size": attributes[NSURLFileSizeKey],
            @"lastModified": [dateFormatter stringFromDate:attributes[NSURLContentModificationDateKey]],
            @"isDirectory": attributes[NSURLIsDirectoryKey],
            @"isFile": attributes[NSURLIsRegularFileKey],
            @"isDownloaded": attributes[NSURLUbiquitousItemIsDownloadedKey],
        }];
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSMetadataQueryDidFinishGatheringNotification object:query];
    RNCloudFsQueryCallback *queryCallback;
    for (RNCloudFsQueryCallback *callback in self.queryCallbacks) {
        if (![callback.query isEqual:query]) {
            continue;
        }
        queryCallback = callback;
        break;
    }
    if (queryCallback) {
        [self.queryCallbacks removeObject:queryCallback];
        queryCallback.callback(filesArray);
    }
    NSLog(@"%@", filesArray);
    self.queryData = nil;
}

@end

@interface RNCloudFs ()

@property (nonatomic, strong) RNCloudFsFilesListQuery *filesListQuery;
@property (nonatomic, strong) NSFileCoordinator *fileCoordinator;

@end


@implementation RNCloudFs

- (instancetype)init {
    self = [super init];
    if (self) {
        self.filesListQuery = [[RNCloudFsFilesListQuery alloc] init];
        self.fileCoordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    }
    return self;
}

- (dispatch_queue_t)methodQueue
{
    return dispatch_queue_create("RNCloudFs.queue", DISPATCH_QUEUE_SERIAL);
}

+ (BOOL)requiresMainQueueSetup {
    return NO;
}

RCT_EXPORT_MODULE()

//see https://developer.apple.com/library/content/documentation/General/Conceptual/iCloudDesignGuide/Chapters/iCloudFundametals.html

RCT_EXPORT_METHOD(createFile:(NSDictionary *) options
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {

    NSString *destinationPath = [options objectForKey:@"targetPath"];
    NSString *content = [options objectForKey:@"content"];
    NSString *scope = [options objectForKey:@"scope"];
    bool documentsFolder = !scope || [scope caseInsensitiveCompare:@"visible"] == NSOrderedSame;

    NSString *tempFile = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];

    NSError *error;
    [content writeToFile:tempFile atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if(error) {
        return reject(@"error", error.description, nil);
    }

    [self moveToICloudDirectory:documentsFolder :tempFile :destinationPath :resolve :reject];
}

RCT_EXPORT_METHOD(fileExists:(NSDictionary *)options
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {

    NSString *destinationPath = [options objectForKey:@"targetPath"];
    NSString *scope = [options objectForKey:@"scope"];
    bool documentsFolder = !scope || [scope caseInsensitiveCompare:@"visible"] == NSOrderedSame;

    NSFileManager* fileManager = [NSFileManager defaultManager];

    NSURL *ubiquityURL = documentsFolder ? [self icloudDocumentsDirectory] : [self icloudDirectory];

    if (ubiquityURL) {
        NSURL* dir = [ubiquityURL URLByAppendingPathComponent:destinationPath];
        NSString* dirPath = [dir.path stringByStandardizingPath];

        bool exists = [fileManager fileExistsAtPath:dirPath];

        return resolve(@(exists));
    } else {
        RCTLogTrace(@"Could not retrieve a ubiquityURL");
        return reject(@"error", [NSString stringWithFormat:@"could access iCloud drive '%@'", destinationPath], nil);
    }
}

RCT_EXPORT_METHOD(listFiles:(NSDictionary *)options
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    NSString *destinationPath = [options objectForKey:@"targetPath"];
    NSString *scope = [options objectForKey:@"scope"];
    bool documentsFolder = !scope || [scope caseInsensitiveCompare:@"visible"] == NSOrderedSame;

    NSFileManager* fileManager = [NSFileManager defaultManager];

    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZZZ"];

    NSURL *ubiquityURL = documentsFolder ? [self icloudDocumentsDirectory] : [self icloudDirectory];

    if (ubiquityURL) {
        NSURL *target = [ubiquityURL URLByAppendingPathComponent:destinationPath];

        [self.filesListQuery listFilesAtPath:target.path callback:^(NSArray *filesList) {
            return resolve(@{ @"files": filesList });
        }];
        return;
    } else {
        NSLog(@"Could not retrieve a ubiquityURL");
        return reject(@"error", [NSString stringWithFormat:@"could not copy to iCloud drive '%@'", destinationPath], nil);
    }
}

RCT_EXPORT_METHOD(downloadFile:(NSDictionary *)options
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {
    NSURL *url = [NSURL fileURLWithPath:[options objectForKey:@"targetPath"]];
    NSError *error = nil;
    BOOL success = [[NSFileManager defaultManager] startDownloadingUbiquitousItemAtURL:url error:&error];
    if (!success) {
        NSLog(@"failed to start download");
        return reject(@"error", @"Failed to start download", nil);
    } else {
        NSDictionary *attrs = [url resourceValuesForKeys:@[NSURLUbiquitousItemIsDownloadedKey] error:&error];
        NSLog(@"%@ attributes: %@", url.lastPathComponent, attrs);
        if (attrs != nil) {
            if ([[attrs objectForKey:NSURLUbiquitousItemIsDownloadedKey] boolValue]) {
                NSLog(@"File already downloaded");
                return resolve(@{});
            } else {
                NSError *error2 = nil;
                [self.fileCoordinator coordinateReadingItemAtURL:url options:0 error:&error2 byAccessor:^(NSURL * _Nonnull newURL) {
                    NSLog(@"File downloaded: %@", newURL.lastPathComponent);
                    return resolve(@{});
                }];
            }
        } else {
            return reject(@"error", @"File already downloaded", nil);
        }
    }
}

RCT_EXPORT_METHOD(copyToCloud:(NSDictionary *)options
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject) {

    // mimeType is ignored for iOS
    NSDictionary *source = [options objectForKey:@"sourcePath"];
    NSString *destinationPath = [options objectForKey:@"targetPath"];
    NSString *scope = [options objectForKey:@"scope"];
    bool documentsFolder = !scope || [scope caseInsensitiveCompare:@"visible"] == NSOrderedSame;

    NSFileManager* fileManager = [NSFileManager defaultManager];

    NSString *sourceUri = [source objectForKey:@"uri"];
    if(!sourceUri) {
        sourceUri = [source objectForKey:@"path"];
    }

    if([sourceUri hasPrefix:@"assets-library"]){
        ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];

        [library assetForURL:[NSURL URLWithString:sourceUri] resultBlock:^(ALAsset *asset) {

            ALAssetRepresentation *rep = [asset defaultRepresentation];

            Byte *buffer = (Byte*)malloc(rep.size);
            NSUInteger buffered = [rep getBytes:buffer fromOffset:0.0 length:rep.size error:nil];
            NSData *data = [NSData dataWithBytesNoCopy:buffer length:buffered freeWhenDone:YES];

            if (data) {
                NSString *filename = [sourceUri lastPathComponent];
                NSString *tempFile = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
                [data writeToFile:tempFile atomically:YES];
                [self moveToICloudDirectory:documentsFolder :tempFile :destinationPath :resolve :reject];
            } else {
                RCTLogTrace(@"source file does not exist %@", sourceUri);
                return reject(@"error", [NSString stringWithFormat:@"failed to copy asset '%@'", sourceUri], nil);
            }
        } failureBlock:^(NSError *error) {
            RCTLogTrace(@"source file does not exist %@", sourceUri);
            return reject(@"error", error.description, nil);
        }];
    } else if ([sourceUri hasPrefix:@"file:/"] || [sourceUri hasPrefix:@"/"]) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^file:/+" options:NSRegularExpressionCaseInsensitive error:nil];
        NSString *modifiedSourceUri = [regex stringByReplacingMatchesInString:sourceUri options:0 range:NSMakeRange(0, [sourceUri length]) withTemplate:@"/"];

        if ([fileManager fileExistsAtPath:modifiedSourceUri isDirectory:nil]) {
            NSURL *sourceURL = [NSURL fileURLWithPath:modifiedSourceUri];

            // todo: figure out how to *copy* to icloud drive
            // ...setUbiquitous will move the file instead of copying it, so as a work around lets copy it to a tmp file first
            NSString *filename = [sourceUri lastPathComponent];
            NSString *tempFile = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];

            NSError *error;
            [fileManager copyItemAtPath:[sourceURL path] toPath:tempFile error:&error];
            if(error) {
                return reject(@"error", error.description, nil);
            }

            [self moveToICloudDirectory:documentsFolder :tempFile :destinationPath :resolve :reject];
        } else {
            NSLog(@"source file does not exist %@", sourceUri);
            return reject(@"error", [NSString stringWithFormat:@"no such file or directory, open '%@'", sourceUri], nil);
        }
    } else {
        NSURL *url = [NSURL URLWithString:sourceUri];
        NSData *urlData = [NSData dataWithContentsOfURL:url];

        if (urlData) {
            NSString *filename = [sourceUri lastPathComponent];
            NSString *tempFile = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
            [urlData writeToFile:tempFile atomically:YES];
            [self moveToICloudDirectory:documentsFolder :tempFile :destinationPath :resolve :reject];
        } else {
            RCTLogTrace(@"source file does not exist %@", sourceUri);
            return reject(@"error", [NSString stringWithFormat:@"cannot download '%@'", sourceUri], nil);
        }
    }
}

- (void) moveToICloudDirectory:(bool) documentsFolder :(NSString *)tempFile :(NSString *)destinationPath
                              :(RCTPromiseResolveBlock)resolver
                              :(RCTPromiseRejectBlock)rejecter {

    if(documentsFolder) {
        NSURL *ubiquityURL = [self icloudDocumentsDirectory];
        [self moveToICloud:ubiquityURL :tempFile :destinationPath :resolver :rejecter];
    } else {
        NSURL *ubiquityURL = [self icloudDirectory];
        [self moveToICloud:ubiquityURL :tempFile :destinationPath :resolver :rejecter];
    }
}

- (void) moveToICloud:(NSURL *)ubiquityURL :(NSString *)tempFile :(NSString *)destinationPath
                     :(RCTPromiseResolveBlock)resolver
                     :(RCTPromiseRejectBlock)rejecter {


    NSString * destPath = destinationPath;
    while ([destPath hasPrefix:@"/"]) {
        destPath = [destPath substringFromIndex:1];
    }

    RCTLogTrace(@"Moving file %@ to %@", tempFile, destPath);

    NSFileManager* fileManager = [NSFileManager defaultManager];

    if (ubiquityURL) {

        NSURL* targetFile = [ubiquityURL URLByAppendingPathComponent:destPath];
        NSURL *dir = [targetFile URLByDeletingLastPathComponent];
        NSString *name = [targetFile lastPathComponent];

        NSURL* uniqueFile = targetFile;

        int count = 1;
        while([fileManager fileExistsAtPath:uniqueFile.path]) {
            NSString *uniqueName = [NSString stringWithFormat:@"%i.%@", count, name];
            uniqueFile = [dir URLByAppendingPathComponent:uniqueName];
            count++;
        }

        RCTLogTrace(@"Target file: %@", uniqueFile.path);

        if (![fileManager fileExistsAtPath:dir.path]) {
            [fileManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        }

        NSError *error;
        [fileManager setUbiquitous:YES itemAtURL:[NSURL fileURLWithPath:tempFile] destinationURL:uniqueFile error:&error];
        if(error) {
            return rejecter(@"error", error.description, nil);
        }

        [fileManager removeItemAtPath:tempFile error:&error];

        return resolver(uniqueFile.path);
    } else {
        NSError *error;
        [fileManager removeItemAtPath:tempFile error:&error];

        return rejecter(@"error", [NSString stringWithFormat:@"could not copy '%@' to iCloud drive", tempFile], nil);
    }
}

- (NSURL *)icloudDocumentsDirectory {
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSURL *rootDirectory = [[self icloudDirectory] URLByAppendingPathComponent:@"Documents"];

    if (rootDirectory) {
        if (![fileManager fileExistsAtPath:rootDirectory.path isDirectory:nil]) {
            RCTLogTrace(@"Creating documents directory: %@", rootDirectory.path);
            [fileManager createDirectoryAtURL:rootDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }

    return rootDirectory;
}

- (NSURL *)icloudDirectory {
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSURL *rootDirectory = [fileManager URLForUbiquityContainerIdentifier:nil];
    return rootDirectory;
}

- (NSURL *)localPathForResource:(NSString *)resource ofType:(NSString *)type {
    NSString *documentsDirectory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *resourcePath = [[documentsDirectory stringByAppendingPathComponent:resource] stringByAppendingPathExtension:type];
    return [NSURL fileURLWithPath:resourcePath];
}

@end
