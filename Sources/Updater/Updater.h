// Shared release updater. Change the product constants in Updater.m when copying it to another app.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString * _Nullable updaterVersion(id _Nullable value);
NSComparisonResult updaterCompareVersions(NSString *left, NSString *right);
NSString *updaterAssetName(NSString *version);
BOOL updaterAssetSizeValid(id _Nullable value);
NSString *updaterRequirement(void);
int updaterRun(BOOL install);

NS_ASSUME_NONNULL_END
