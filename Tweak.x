// FreeGrid - free icon placement on the iOS 9 home screen.
//
// Two modes (Settings > FreeGrid > Mode):
//
// GRID mode: any icon can sit in ANY grid slot, leaving gaps (iOS 18 style).
//   Every root-folder page (SBIconListModel) is kept "dense": its entries map 1:1 to grid
//   slots. Empty slots BEFORE the last icon are filled with invisible placeholder icons
//   ("gaps", see MakeGap). Stock SpringBoard already lays out and ignores SBPlaceholderIcon,
//   so we only teach the model:
//     * removing an icon leaves a gap instead of shifting the rest,
//     * inserting onto a gap swaps it in (nothing moves),
//     * inserting onto an icon pushes icons along only until the first gap,
//     * dropping past the last icon pads the page with gaps up to the touched slot,
//     * compaction keeps gaps but trims trailing ones.
//
// FREE mode: icons sit at arbitrary pixel positions (overlap, circles, ...). Each icon has
//   its own saved origin; the page list view's origin/center methods return it instead of
//   the grid slot. The model itself stays stock (no gaps).
//
// Folders and the dock are never touched. Safety: touch /var/mobile/.freegrid_disable to make
// the tweak do nothing; three launches in a row that crash disable it automatically.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <signal.h>
#import <unistd.h>

static NSString *const kKillSwitch   = @"/var/mobile/.freegrid_disable";
static NSString *const kBootFile     = @"/var/mobile/Library/Preferences/com.example.freegrid.boot";
static NSString *const kLogPath      = @"/var/mobile/Library/Logs/freegrid.log";
static NSString *const kGapPrefix    = @"FreeGrid.gap.";
static NSString *const kDebugFile    = @"/var/mobile/.freegrid_debug";
static NSString *const kLayoutPath   = @"/var/mobile/Library/Preferences/com.example.freegrid.plist";
static NSString *const kSettingsDom  = @"com.example.freegrid.settings"; // written by the Settings page
static NSString *const kNotifyName   = @"com.example.freegrid/settings";

#pragma mark - Logging

static BOOL sDebug = NO; // verbose tracing only if /var/mobile/.freegrid_debug exists

static void FGLogErr(NSString *fmt, ...) {
	va_list ap; va_start(ap, fmt);
	NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);
	NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
	if (!fh) {
		[[NSFileManager defaultManager] createFileAtPath:kLogPath contents:nil attributes:nil];
		fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
	}
	[fh seekToEndOfFile];
	[fh writeData:[[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
	[fh closeFile];
}

#define FGLog(...) do { if (sDebug) FGLogErr(__VA_ARGS__); } while (0)

#pragma mark - Private SpringBoard interfaces (iOS 9.3.6)

typedef struct { int a; int b; } SBIconCoordinate; // {row, column}; we only pass it back to SpringBoard

@interface SBIcon : NSObject
- (BOOL)isPlaceholder;
- (BOOL)isEmptyPlaceholder;
- (BOOL)isGrabbedIconPlaceholder;
- (BOOL)isFolderIcon;
- (NSString *)nodeIdentifier;
- (NSString *)leafIdentifier;
- (NSString *)displayName;
@end

@interface SBPlaceholderIcon : SBIcon
- (id)_initWithNodeIdentifier:(NSString *)ident icon:(id)icon;
@end

@class SBIconListModel;
@interface SBFolder : NSObject
- (BOOL)isRootFolder;
- (NSArray *)lists;
- (NSString *)displayName;
- (void)setDisplayName:(NSString *)name;
@end
@interface SBRootFolder : SBFolder
- (SBIconListModel *)dock;
@end

@interface SBIconListModel : NSObject
- (SBFolder *)folder;
- (unsigned)numberOfIcons;
- (unsigned)maxNumberOfIcons;
- (SBIcon *)iconAtIndex:(unsigned)i;
- (void)removeIconAtIndex:(unsigned)i;
- (id)insertIcon:(SBIcon *)icon atIndex:(unsigned *)i;
- (id)placeIcon:(SBIcon *)icon atIndex:(unsigned *)i;
@end

@interface SBIconView : UIView
+ (CGPoint)defaultIconImageCenter;
@end

@interface SBIconViewMap : NSObject
- (SBIconView *)mappedIconViewForIcon:(SBIcon *)icon;
@end

@interface SBFolderController : NSObject
- (SBFolder *)folder;
- (id)delegate;
- (id)iconListViewForTouch:(UITouch *)touch;
- (SBIconViewMap *)viewMap;
- (id)iconListViewAtIndex:(unsigned)i;
@end

@interface SBIconController : NSObject
+ (id)sharedInstance;
- (SBFolderController *)_rootFolderController;
- (BOOL)folderController:(id)fc draggedIconDidPauseAtLocation:(CGPoint)p inListView:(id)lv;
@end

@interface SBIconStateArchiver : NSObject
+ (id)_representationForIcon:(SBIcon *)icon;
@end

@interface SBIconModel : NSObject
- (SBFolder *)rootFolder;
@end

@interface SBIconListView : UIView
- (SBIconListModel *)model;
- (unsigned)columnAtPoint:(CGPoint)p;
- (unsigned)rowAtPoint:(CGPoint)p;
- (unsigned)iconColumnsForCurrentOrientation;
- (int)orientation;
- (Class)baseIconViewClass;
- (SBIconCoordinate)iconCoordinateForIndex:(unsigned)i forOrientation:(int)o;
- (CGPoint)originForIconAtCoordinate:(SBIconCoordinate)c;
- (CGPoint)originForIconAtIndex:(unsigned)i;
@end

#pragma mark - Mode + helpers

static BOOL sEnabled = YES;                       // master switch, read once at launch
static BOOL sFreeMode = NO;                       // set once at launch from the Settings page
static NSArray *sInheritPos;                      // a new folder takes over the position of the icon it replaces
static NSTimeInterval sInheritUntil;
static NSMutableDictionary *sFree;                // FREE mode: icon key -> @[x, y] (icon view origin)

// FREE mode drag state: where the dragged icon's view currently is (list-view coordinates).
static CGPoint sDragOrigin;
static BOOL sDragValid = NO;
static __weak SBIcon *sDragIcon;

// Set while WE call model methods, so our hooks don't recurse.
static BOOL sInternal = NO;

static BOOL IsGap(SBIcon *icon) {
	if (!icon) return NO;
	id ident = [icon nodeIdentifier];
	return [ident isKindOfClass:[NSString class]] && [ident hasPrefix:kGapPrefix];
}

// Structurally: a page of the root folder (never the dock, folders or anything unknown).
static BOOL IsRootPage(SBIconListModel *m) {
	if (!m) return NO;
	SBFolder *f = [m folder];
	if (!f || ![f isRootFolder]) return NO;
	if ([(SBRootFolder *)f dock] == m) return NO;
	return [m maxNumberOfIcons] > 4; // pages are 16, dock is 4
}

// Pages whose model we reshape (GRID mode only).
static BOOL IsGridPage(SBIconListModel *m) {
	return !sFreeMode && IsRootPage(m);
}

static SBIcon *MakeGap(void) {
	static unsigned counter = 0; // unique id: the list indexes icons by identifier
	NSString *ident = [NSString stringWithFormat:@"%@%u", kGapPrefix, ++counter];
	return [[objc_getClass("SBPlaceholderIcon") alloc] _initWithNodeIdentifier:ident icon:nil];
}

static NSString *Describe(SBIconListModel *m) {
	NSMutableArray *a = [NSMutableArray array];
	for (unsigned i = 0; i < [m numberOfIcons]; i++) {
		SBIcon *ic = [m iconAtIndex:i];
		NSString *s = IsGap(ic) ? @"_" : [ic isGrabbedIconPlaceholder] ? @"GRAB"
		            : [ic isEmptyPlaceholder] ? @"EMPTY" : [ic isFolderIcon] ? @"[F]"
		            : [ic nodeIdentifier];
		[a addObject:s ?: @"nil"];
	}
	return [a componentsJoinedByString:@" "];
}

static NSString *IconKey(SBIcon *ic) {
	if ([ic isFolderIcon]) return [@"folder:" stringByAppendingString:[ic displayName] ?: @""];
	return [ic leafIdentifier] ?: [ic nodeIdentifier] ?: @"?";
}

// Real icons of a page as keys; optionally also the gap slot indexes.
static NSArray *PageKeys(SBIconListModel *list, NSMutableArray *gapsOut) {
	NSMutableArray *keys = [NSMutableArray array];
	for (unsigned i = 0; i < [list numberOfIcons]; i++) {
		SBIcon *ic = [list iconAtIndex:i];
		if (IsGap(ic)) { [gapsOut addObject:@(i)]; continue; }
		if (!ic || [ic isPlaceholder]) continue;
		[keys addObject:IconKey(ic)];
	}
	return keys;
}

#pragma mark - GRID mode: model hooks (the core)

%hook SBIconListModel

// Removing an icon (or the "grabbed" stand-in) leaves a gap, so nothing shifts.
- (void)removeIconAtIndex:(unsigned)idx {
	BOOL handle = NO;
	SBIcon *old = nil;
	if (!sInternal) {
		@try {
			handle = IsGridPage(self) && idx < [self numberOfIcons];
			if (handle) old = [self iconAtIndex:idx];
		} @catch (NSException *e) {
			FGLogErr(@"remove precheck threw %@: %@", e.name, e.reason);
			handle = NO;
		}
	}
	%orig;
	if (!handle || !old) return;
	if ([old isPlaceholder] && ![old isGrabbedIconPlaceholder]) return; // gaps / stock holes just go away
	@try {
		sInternal = YES;
		unsigned at = idx;
		[self insertIcon:MakeGap() atIndex:&at];
		FGLog(@"remove@%u -> [%@]", idx, Describe(self));
	} @catch (NSException *e) {
		FGLogErr(@"remove gap-insert threw %@: %@", e.name, e.reason);
	}
	sInternal = NO;
}

- (id)insertIcon:(SBIcon *)icon atIndex:(unsigned *)idxp {
	// FREE: when the dragged icon is dropped onto a page, it keeps the position it had under the finger.
	if (sFreeMode && !sInternal && sDragValid && icon && icon == sDragIcon) {
		@try {
			if (IsRootPage(self)) {
				sFree[IconKey(icon)] = @[@(sDragOrigin.x), @(sDragOrigin.y)];
				sDragValid = NO;
				FGLog(@"free drop: %@ at (%.0f,%.0f)", IconKey(icon), sDragOrigin.x, sDragOrigin.y);
			}
		} @catch (NSException *e) {
			FGLogErr(@"free drop threw %@: %@", e.name, e.reason);
		}
	}
	BOOL handle = NO;
	unsigned idx = 0;
	if (!sInternal && idxp && icon) {
		@try {
			handle = IsGridPage(self);
			if (handle) {
				sInternal = YES;
				unsigned max = [self maxNumberOfIcons];
				unsigned n = [self numberOfIcons];
				idx = *idxp;
				if (idx >= max) idx = max - 1;
				// Dropping past the last icon: pad with gaps up to the touched slot.
				while (n < idx) { unsigned at = n; [self insertIcon:MakeGap() atIndex:&at]; n++; }
				if (idx < n && IsGap([self iconAtIndex:idx])) {
					// Target is a gap: swap the icon in, nothing else moves.
					[self removeIconAtIndex:idx];
				} else {
					// Target is occupied: icons after it are pushed, but only up to the first gap, which we absorb.
					for (unsigned g = idx + 1; g < n; g++) {
						if (IsGap([self iconAtIndex:g])) { [self removeIconAtIndex:g]; break; }
					}
				}
			}
		} @catch (NSException *e) {
			FGLogErr(@"insert prep threw %@: %@", e.name, e.reason);
			handle = NO;
		}
		sInternal = NO;
	}
	if (handle) *idxp = idx;
	id r = %orig;
	if (handle) FGLog(@"insert %@ @%u -> [%@]", [icon nodeIdentifier], idx, Describe(self));
	return r;
}

// Placing onto a gap must not report the gap as "displaced" (it would get cascaded to the next page).
- (id)placeIcon:(SBIcon *)icon atIndex:(unsigned *)idxp {
	BOOL onGap = NO;
	if (!sInternal && idxp) {
		@try {
			onGap = IsGridPage(self) && *idxp < [self numberOfIcons] && IsGap([self iconAtIndex:*idxp]);
		} @catch (NSException *e) {
			FGLogErr(@"place precheck threw %@: %@", e.name, e.reason);
		}
	}
	id r = %orig;
	return onGap ? nil : r;
}

// Stock compaction would delete placeholders. Instead: stock "EMPTY" holes become gaps,
// our gaps stay, and trailing gaps are trimmed (so an all-gap page counts as empty).
- (unsigned)compactIcons {
	BOOL handle = NO;
	if (!sInternal) {
		@try { handle = IsGridPage(self); } @catch (NSException *e) { FGLogErr(@"compact precheck threw %@: %@", e.name, e.reason); }
	}
	if (!handle) return %orig;
	// Stock returns the index of the removed empty placeholder, or NSNotFound; the list view
	// loops on it and animates icons into the hole. We never leave a hole (holes become gaps),
	// so we always report NSNotFound.
	@try {
		sInternal = YES;
		for (unsigned i = 0; i < [self numberOfIcons]; i++) {
			SBIcon *ic = [self iconAtIndex:i];
			if ([ic isEmptyPlaceholder] && !IsGap(ic)) {
				[self removeIconAtIndex:i];
				unsigned at = i; [self insertIcon:MakeGap() atIndex:&at];
			}
		}
		// Trim trailing gaps (an all-gap page becomes empty). Stop if the count does not shrink.
		for (int guard = 0; guard < 32; guard++) {
			unsigned cnt = [self numberOfIcons];
			if (cnt == 0 || !IsGap([self iconAtIndex:cnt - 1])) break;
			[self removeIconAtIndex:cnt - 1];
			FGLog(@"trim: count %u -> %u", cnt, [self numberOfIcons]);
			if ([self numberOfIcons] >= cnt) break;
		}
		FGLog(@"compact -> [%@]", Describe(self));
	} @catch (NSException *e) {
		FGLogErr(@"compact threw %@: %@", e.name, e.reason);
	}
	sInternal = NO;
	return NSNotFound;
}

%end

#pragma mark - FREE mode: where does an icon with no saved position go?

static BOOL OverlapsAnother(CGPoint p, SBIconListModel *m, SBIcon *except) {
	for (unsigned i = 0; i < [m numberOfIcons]; i++) {
		SBIcon *other = [m iconAtIndex:i];
		if (!other || other == except || [other isPlaceholder]) continue;
		NSArray *q = sFree[IconKey(other)];
		if (q.count == 2 && fabs([q[0] floatValue] - p.x) < 30 && fabs([q[1] floatValue] - p.y) < 30) return YES;
	}
	return NO;
}

// Its stock slot if that is free, otherwise the first grid slot that does not sit on another icon.
static CGPoint FreeSpot(SBIconListView *lv, SBIconListModel *m, SBIcon *ic, CGPoint stock) {
	if (!OverlapsAnother(stock, m, ic)) return stock;
	for (unsigned s = 0; s < [m maxNumberOfIcons]; s++) {
		CGPoint so = [lv originForIconAtCoordinate:[lv iconCoordinateForIndex:s forOrientation:[lv orientation]]];
		if (!OverlapsAnother(so, m, ic)) return so;
	}
	return stock;
}

#pragma mark - Drag target + FREE mode geometry (list view)

%hook SBIconListView

// Stock decides where a dragged icon goes from this call.
//
// GRID: for an EMPTY target (a gap, or space past the last icon) we answer "no icon here, insert
//   at this exact slot". The consumer does nothing when proposedOrder == 0, so we set 1 (before) /
//   3 (after): with the placeholder on the far side of the slot neither value shifts the index.
// FREE: stock would hit-test the grid, which is meaningless here. We hit-test the real icon
//   positions instead: finger on an icon's center -> folder drop (order 2); anywhere else -> the
//   placeholder stays where it is (or goes to the end of a page it is not on yet).
- (id)iconAtPoint:(CGPoint)p index:(unsigned *)idxp proposedOrder:(int *)order grabbedIcon:(id)grabbed {
	id r = %orig;
	@try {
		SBIconListModel *m = [self model];
		if (!idxp) return r;

		if (sFreeMode) {
			if (!IsRootPage(m)) return r;
			unsigned n = [m numberOfIcons];
			int cur = -1;
			SBIcon *hit = nil; unsigned hitIdx = 0;
			CGPoint imgC = [[self baseIconViewClass] defaultIconImageCenter];
			for (unsigned i = 0; i < n; i++) {
				SBIcon *ic = [m iconAtIndex:i];
				if ([ic isGrabbedIconPlaceholder]) { cur = (int)i; continue; }
				if (hit || !ic || [ic isPlaceholder]) continue;
				CGPoint o = [self originForIconAtIndex:i];
				if (hypot(p.x - (o.x + imgC.x), p.y - (o.y + imgC.y)) < 22.0) { hit = ic; hitIdx = i; }
			}
			if (hit) { *idxp = hitIdx; if (order) *order = 2; return hit; }
			*idxp = cur >= 0 ? (unsigned)cur : n;
			if (order) *order = 3;
			return nil;
		}

		if (!IsGridPage(m)) return r;
		unsigned cols = [self iconColumnsForCurrentOrientation];
		unsigned slot = [self rowAtPoint:p] * cols + [self columnAtPoint:p];
		if (cols == 0 || slot >= [m maxNumberOfIcons]) return r;

		unsigned n = [m numberOfIcons];
		SBIcon *target = slot < n ? [m iconAtIndex:slot] : nil;
		if (target && !IsGap(target)) return r; // real icon under the finger: stock logic (push / folder)

		int cur = -1; // where the dragged placeholder sits in this page (-1: not here)
		for (unsigned i = 0; i < n; i++) if ([[m iconAtIndex:i] isGrabbedIconPlaceholder]) { cur = (int)i; break; }
		*idxp = slot;
		if (order) *order = (cur > (int)slot) ? 1 : 3;
		FGLog(@"iconAtPoint: empty slot %u (cur %d) order %d", slot, cur, order ? *order : -1);
		return nil;
	} @catch (NSException *e) {
		FGLogErr(@"iconAtPoint threw %@: %@", e.name, e.reason);
	}
	return r;
}

// FREE: the icon view's frame origin comes from the icon's own saved position.
// An icon seen for the first time is pinned at its stock slot so it never jumps afterwards.
- (CGPoint)originForIconAtIndex:(unsigned)idx {
	CGPoint o = %orig;
	if (!sFreeMode) return o;
	@try {
		SBIconListModel *m = [self model];
		if (!IsRootPage(m) || idx >= [m numberOfIcons]) return o;
		SBIcon *ic = [m iconAtIndex:idx];
		if (!ic || [ic isPlaceholder]) return o;
		NSString *key = IconKey(ic);
		NSArray *pos = sFree[key];
		if (pos.count == 2) return CGPointMake([pos[0] floatValue], [pos[1] floatValue]);
		// A page that has not been sized yet makes stock return garbage (negative x...): never pin that.
		CGSize sz = [self bounds].size;
		if (sz.width < 200 || sz.height < 200) return o;
		CGPoint pick;
		if (sInheritPos && [ic isFolderIcon] && [NSDate timeIntervalSinceReferenceDate] < sInheritUntil) {
			pick = CGPointMake([sInheritPos[0] floatValue], [sInheritPos[1] floatValue]); // new folder replaces the icon it was made from
			sInheritPos = nil;
		} else {
			pick = FreeSpot(self, m, ic, o);
		}
		sFree[key] = @[@(pick.x), @(pick.y)];
		FGLog(@"pin %@ idx %u stock (%.0f,%.0f) -> (%.0f,%.0f)", key, idx, o.x, o.y, pick.x, pick.y);
		return pick;
	} @catch (NSException *e) {
		FGLogErr(@"origin threw %@: %@", e.name, e.reason);
	}
	return o;
}

// FREE: stock derives the center from the grid coordinate; use origin + image center instead.
- (CGPoint)centerForIcon:(SBIcon *)ic {
	CGPoint c = %orig;
	if (!sFreeMode || !ic || [ic isPlaceholder]) return c;
	@try {
		if (!IsRootPage([self model])) return c;
		NSArray *pos = sFree[IconKey(ic)];
		if (pos.count != 2) return c;
		CGPoint imgC = [[self baseIconViewClass] defaultIconImageCenter];
		return CGPointMake([pos[0] floatValue] + imgC.x, [pos[1] floatValue] + imgC.y);
	} @catch (NSException *e) {
		FGLogErr(@"center threw %@: %@", e.name, e.reason);
	}
	return c;
}

%end

#pragma mark - Saving: gaps never reach IconState.plist

// The stock archiver cannot serialize placeholders (it throws). For root pages we archive
// every real icon and skip gaps, so IconState.plist stays a normal dense list.
%hook SBIconStateArchiver
+ (id)_representationForList:(SBIconListModel *)list {
	BOOL handle = NO;
	@try { handle = IsGridPage(list); } @catch (NSException *e) { FGLogErr(@"archive precheck threw %@: %@", e.name, e.reason); }
	if (!handle) return %orig;
	@try {
		NSMutableArray *out = [NSMutableArray array];
		for (unsigned i = 0; i < [list numberOfIcons]; i++) {
			SBIcon *ic = [list iconAtIndex:i];
			if (!ic || [ic isPlaceholder]) continue;
			id rep = [self _representationForIcon:ic];
			if (rep) [out addObject:rep];
		}
		return out;
	} @catch (NSException *e) {
		FGLogErr(@"archive threw %@: %@ - falling back to stock", e.name, e.reason);
	}
	return %orig;
}
%end

#pragma mark - Persistence (com.example.freegrid.plist)
//
// IconState.plist stays a normal dense list. Our file (version 2) holds:
//   mode  : "grid" | "free"   (the representation below is for this mode only)
//   pages : per root page { icons: keys in page order, gaps: slot indexes of the gaps }
//   free  : FREE mode only, icon key -> [x, y]

static BOOL WriteLayout(NSString *mode, NSArray *pages, NSDictionary *free) {
	NSMutableDictionary *d = [@{@"version": @2, @"mode": mode, @"pages": pages} mutableCopy];
	if (free) d[@"free"] = free;
	return [d writeToFile:kLayoutPath atomically:YES];
}

static void SaveLayout(SBFolder *root) {
	NSMutableArray *pages = [NSMutableArray array];
	NSMutableSet *present = [NSMutableSet set];
	BOOL anyGap = NO;
	for (SBIconListModel *list in [root lists]) {
		NSMutableArray *gaps = [NSMutableArray array];
		NSArray *keys = PageKeys(list, gaps);
		if (gaps.count) anyGap = YES;
		[present addObjectsFromArray:keys];
		[pages addObject:@{@"icons": keys, @"gaps": gaps}];
	}
	if (sFreeMode) {
		for (NSString *k in [sFree allKeys]) if (![present containsObject:k]) [sFree removeObjectForKey:k];
		if (!sFree.count) { [[NSFileManager defaultManager] removeItemAtPath:kLayoutPath error:nil]; return; }
		WriteLayout(@"free", pages, sFree);
	} else {
		if (!anyGap) { // nothing to remember: stock layout, no file
			[[NSFileManager defaultManager] removeItemAtPath:kLayoutPath error:nil];
			return;
		}
		WriteLayout(@"grid", pages, nil);
	}
	FGLog(@"saved layout (%@): %@", sFreeMode ? @"free" : @"grid", pages);
}

static BOOL SameMultiset(NSArray *a, NSArray *b) {
	return [[a sortedArrayUsingSelector:@selector(compare:)] isEqualToArray:[b sortedArrayUsingSelector:@selector(compare:)]];
}

// Put the real icons of a freshly built page into the saved order (no views exist yet).
static void ReorderPage(SBIconListModel *list, NSArray *order) {
	NSMutableArray *icons = [NSMutableArray array];
	for (unsigned i = 0; i < [list numberOfIcons]; i++) {
		SBIcon *ic = [list iconAtIndex:i];
		if (ic && ![ic isPlaceholder]) [icons addObject:ic];
	}
	NSMutableArray *sorted = [NSMutableArray array];
	for (NSString *key in order) {
		for (SBIcon *ic in icons) if ([IconKey(ic) isEqualToString:key]) { [sorted addObject:ic]; [icons removeObject:ic]; break; }
	}
	if (sorted.count != order.count) return; // inconsistent: leave as is
	sInternal = YES;
	while ([list numberOfIcons] > 0) [list removeIconAtIndex:[list numberOfIcons] - 1];
	for (SBIcon *ic in sorted) { unsigned at = [list numberOfIcons]; [list insertIcon:ic atIndex:&at]; }
	sInternal = NO;
}

static void ApplyLayout(SBFolder *root) {
	NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:kLayoutPath];
	if (![saved isKindOfClass:[NSDictionary class]]) return;
	int version = [saved[@"version"] intValue];
	if (version != 1 && version != 2) return;
	BOOL savedFree = [saved[@"mode"] isEqual:@"free"]; // version 1 files are grid layouts
	if (savedFree != sFreeMode) { FGLog(@"layout file is for the other mode - ignored"); return; }

	if (sFreeMode) { // FREE: load the per-icon positions of every page that still looks like the one we saved
		NSDictionary *free = saved[@"free"];
		NSArray *fp = saved[@"pages"];
		NSArray *flists = [root lists];
		if (![free isKindOfClass:[NSDictionary class]] || ![fp isKindOfClass:[NSArray class]]) return;
		for (NSUInteger p = 0; p < flists.count && p < fp.count; p++) {
			NSDictionary *sp = fp[p];
			NSArray *savedIcons = [sp isKindOfClass:[NSDictionary class]] ? sp[@"icons"] : nil;
			if (![savedIcons isKindOfClass:[NSArray class]]) continue;
			// A few changes are fine (an app installed while the tweak was off), a different home
			// screen is not (e.g. "Reset Home Screen Layout"): then the page stays stock.
			NSMutableArray *rest = [PageKeys(flists[p], [NSMutableArray array]) mutableCopy];
			NSUInteger missing = 0;
			for (NSString *k in savedIcons) {
				NSUInteger ix = [rest indexOfObject:k];
				if (ix == NSNotFound) missing++; else [rest removeObjectAtIndex:ix];
			}
			if (missing + rest.count > MAX((NSUInteger)2, savedIcons.count / 4)) { FGLog(@"page %lu differs - free positions skipped", (unsigned long)p); continue; }
			for (NSString *k in savedIcons) {
				NSArray *v = free[k];
				if ([k isKindOfClass:[NSString class]] && [v isKindOfClass:[NSArray class]] && v.count == 2
				    && [v[0] isKindOfClass:[NSNumber class]] && [v[1] isKindOfClass:[NSNumber class]]
				    && [v[0] floatValue] > -40 && [v[0] floatValue] < 340 && [v[1] floatValue] > -40 && [v[1] floatValue] < 500) // on screen
					sFree[k] = v;
			}
		}
		FGLog(@"free positions loaded: %lu", (unsigned long)sFree.count);
		return;
	}

	NSArray *savedPages = saved[@"pages"];
	NSArray *lists = [root lists];
	if (![savedPages isKindOfClass:[NSArray class]]) return;

	for (NSUInteger p = 0; p < lists.count && p < savedPages.count; p++) {
		SBIconListModel *list = lists[p];
		NSDictionary *sp = savedPages[p];
		if (![sp isKindOfClass:[NSDictionary class]]) continue;
		NSArray *gaps = sp[@"gaps"];
		NSArray *savedIcons = sp[@"icons"];
		if (![gaps isKindOfClass:[NSArray class]] || ![savedIcons isKindOfClass:[NSArray class]]) continue;

		// The page must hold exactly the icons we saw when saving (any order), otherwise stay stock.
		NSArray *now = PageKeys(list, [NSMutableArray array]);
		if (!SameMultiset(now, savedIcons)) { FGLog(@"page %lu changed - stock layout", (unsigned long)p); continue; }
		if (![now isEqualToArray:savedIcons]) { ReorderPage(list, savedIcons); FGLog(@"page %lu reordered", (unsigned long)p); }
		if (!gaps.count) continue;

		// Gap indexes must be ascending and each one reachable (index <= entries placed so far).
		BOOL ok = ([now count] + gaps.count <= [list maxNumberOfIcons]);
		NSUInteger placed = now.count;
		long prev = -1;
		for (NSNumber *g in gaps) {
			if (![g isKindOfClass:[NSNumber class]] || (long)[g unsignedIntValue] <= prev || [g unsignedIntValue] > placed) { ok = NO; break; }
			prev = [g unsignedIntValue];
			placed++;
		}
		if (!ok) { FGLog(@"page %lu has invalid gaps - stock layout", (unsigned long)p); continue; }

		sInternal = YES;
		for (NSNumber *g in gaps) {
			unsigned at = [g unsignedIntValue];
			[list insertIcon:MakeGap() atIndex:&at];
		}
		sInternal = NO;
		FGLog(@"page %lu restored: [%@]", (unsigned long)p, Describe(list));
	}
}

%hook SBIconModel
// Right after SpringBoard builds the root folder from IconState.plist, re-apply our layout.
- (id)_unarchiveRootFolder {
	id folder = %orig;
	@try {
		if (folder) ApplyLayout(folder);
	} @catch (NSException *e) {
		sInternal = NO;
		FGLogErr(@"apply layout threw %@: %@", e.name, e.reason);
	}
	return folder;
}

// Whenever SpringBoard saves IconState.plist, save our layout too.
- (void)_saveIconState {
	%orig;
	@try {
		SBFolder *root = [self rootFolder];
		if (root) SaveLayout(root);
	} @catch (NSException *e) {
		FGLogErr(@"save layout threw %@: %@", e.name, e.reason);
	}
}
%end

#pragma mark - Dragging: placeholder follows the finger, FREE drop position

// GRID: stock iOS 9 only moves the dragged icon's placeholder after the finger PAUSES, so a quick
//   drop lands where the icon was grabbed. As soon as the finger is over a gap or an empty slot of
//   a root page, we run the stock "paused at location" step immediately. Over a real icon nothing
//   changes (stock pause logic: push icons / make a folder).
// FREE: remember where the dragged icon's view is (that becomes its position on drop), and move
//   the placeholder to a page as soon as the finger is on a page that does not hold it yet.
%hook SBFolderController
- (void)noteGrabbedIcon:(SBIcon *)icon locationDidChangeWithTouch:(UITouch *)touch {
	%orig;
	@try {
		if (![[self folder] isRootFolder]) return;
		SBIconListView *lv = [self iconListViewForTouch:touch];
		SBIconListModel *m = [lv model];
		if (!lv || !IsRootPage(m)) return;

		CGPoint pt = [touch locationInView:lv];
		unsigned n = [m numberOfIcons];
		int cur = -1; // where the placeholder is now in this page (-1: not on this page)
		for (unsigned i = 0; i < n; i++) if ([[m iconAtIndex:i] isGrabbedIconPlaceholder]) { cur = (int)i; break; }

		unsigned slot = 0;
		if (sFreeMode) {
			SBIconView *v = [[self viewMap] mappedIconViewForIcon:icon];
			if (v && [v superview]) {
				CGPoint c = [lv convertPoint:[v center] fromView:[v superview]];
				sDragOrigin = CGPointMake(c.x - [v bounds].size.width / 2, c.y - [v bounds].size.height / 2);
				sDragIcon = icon;
				sDragValid = YES;
			}
			if (cur != -1) return;
		} else {
			unsigned cols = [lv iconColumnsForCurrentOrientation];
			if (cols == 0) return;
			slot = [lv rowAtPoint:pt] * cols + [lv columnAtPoint:pt];
			if (slot >= [m maxNumberOfIcons]) return;
			if (cur == (int)slot) return;
			if (slot < n && !IsGap([m iconAtIndex:slot])) return; // over a real icon: stock behavior
		}

		// One attempt per (touch, page, slot, current position); avoids hammering on every move event.
		static void *lastTouch, *lastView; static unsigned lastSlot; static int lastCur;
		if (lastTouch == (__bridge void *)touch && lastView == (__bridge void *)lv && lastSlot == slot && lastCur == cur) return;
		lastTouch = (__bridge void *)touch; lastView = (__bridge void *)lv; lastSlot = slot; lastCur = cur;

		BOOL moved = [(SBIconController *)[self delegate] folderController:self draggedIconDidPauseAtLocation:pt inListView:lv];
		FGLog(@"follow: slot %u (cur %d) pt (%.0f,%.0f) -> %d", slot, cur, pt.x, pt.y, moved);
	} @catch (NSException *e) {
		FGLogErr(@"follow threw %@: %@", e.name, e.reason);
	}
}
%end

#pragma mark - FREE mode: positions follow folders through renames and creation

// A folder's key is its name, so a rename must carry the saved position over.
%hook SBFolder
- (void)setDisplayName:(NSString *)name {
	NSString *oldKey = nil;
	if (sFreeMode) {
		@try { oldKey = [@"folder:" stringByAppendingString:[self displayName] ?: @""]; } @catch (NSException *e) {}
	}
	%orig;
	if (!oldKey) return;
	@try {
		NSString *newKey = [@"folder:" stringByAppendingString:[self displayName] ?: @""];
		if (![oldKey isEqualToString:newKey] && sFree[oldKey]) {
			sFree[newKey] = sFree[oldKey];
			[sFree removeObjectForKey:oldKey];
			FGLog(@"folder renamed: %@ -> %@", oldKey, newKey);
		}
	} @catch (NSException *e) {
		FGLogErr(@"rename threw %@: %@", e.name, e.reason);
	}
}
%end

// Dropping an icon on the centre of another makes a folder: it should appear where that icon was.
%hook SBIconController
- (id)createNewFolderFromRecipientIcon:(SBIcon *)recipient grabbedIcon:(SBIcon *)grabbed {
	if (sFreeMode && recipient) {
		@try {
			NSArray *pos = sFree[IconKey(recipient)];
			if (pos.count == 2) { sInheritPos = pos; sInheritUntil = [NSDate timeIntervalSinceReferenceDate] + 3.0; }
		} @catch (NSException *e) {
			FGLogErr(@"new folder threw %@: %@", e.name, e.reason);
		}
	}
	return %orig;
}
%end

#pragma mark - Gaps are never launchable

%hook SBPlaceholderIcon
- (BOOL)launchEnabled {
	if (IsGap(self)) return NO;
	return %orig;
}
- (void)launchFromLocation:(int)loc context:(id)ctx {
	if (IsGap(self)) return;
	%orig;
}
%end

#pragma mark - Settings page: mode switch + reset

static id ReadSetting(NSString *key) {
	CFPreferencesAppSynchronize((__bridge CFStringRef)kSettingsDom);
	return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kSettingsDom));
}

static void WriteSetting(NSString *key, id value) {
	CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)kSettingsDom);
	CFPreferencesAppSynchronize((__bridge CFStringRef)kSettingsDom);
}

// Same as `killall -9 SpringBoard`: launchd restarts it. IconState.plist was saved by the last change.
static void Respring(void) {
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		kill(getpid(), SIGKILL);
	});
}

// Convert our saved layout to the other mode, from the LIVE state (list views exist, so we can ask
// stock for the real slot geometry). Only our own plist is written; IconState.plist is untouched.
static BOOL ConvertLayout(BOOL toFree) {
	SBFolderController *rfc = [[objc_getClass("SBIconController") sharedInstance] _rootFolderController];
	NSArray *lists = [[rfc folder] lists];
	SBIconListView *lv0 = [rfc iconListViewAtIndex:0];
	if (!rfc || !lists.count || !lv0) { FGLogErr(@"convert: no root folder / list view"); return NO; }

	unsigned maxSlots = [[lists firstObject] maxNumberOfIcons];
	CGPoint slotOrigin[32];
	if (maxSlots > 32) maxSlots = 32;
	for (unsigned s = 0; s < maxSlots; s++)
		slotOrigin[s] = [lv0 originForIconAtCoordinate:[lv0 iconCoordinateForIndex:s forOrientation:[lv0 orientation]]];

	NSMutableArray *pages = [NSMutableArray array];
	NSMutableDictionary *free = [NSMutableDictionary dictionary];

	for (SBIconListModel *list in lists) {
		// Real icons of this page with their current origin.
		NSMutableArray *items = [NSMutableArray array]; // @{key, x, y, idx}
		for (unsigned i = 0; i < [list numberOfIcons]; i++) {
			SBIcon *ic = [list iconAtIndex:i];
			if (!ic || [ic isPlaceholder]) continue;
			NSString *key = IconKey(ic);
			CGPoint o = (i < maxSlots) ? slotOrigin[i] : CGPointZero; // GRID live state: index == slot
			if (!toFree && sFree[key]) o = CGPointMake([sFree[key][0] floatValue], [sFree[key][1] floatValue]);
			[items addObject:@{@"key": key, @"x": @(o.x), @"y": @(o.y)}];
		}

		if (toFree) {
			NSMutableArray *keys = [NSMutableArray array];
			for (NSDictionary *it in items) { [keys addObject:it[@"key"]]; free[it[@"key"]] = @[it[@"x"], it[@"y"]]; }
			[pages addObject:@{@"icons": keys, @"gaps": @[]}];
		} else {
			// Snap: reading order (top to bottom, left to right), each icon to its nearest free slot.
			NSArray *sorted = [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
				float ya = [a[@"y"] floatValue], yb = [b[@"y"] floatValue];
				if (fabsf(ya - yb) > 20) return ya < yb ? NSOrderedAscending : NSOrderedDescending;
				return [a[@"x"] floatValue] < [b[@"x"] floatValue] ? NSOrderedAscending : NSOrderedDescending;
			}];
			NSMutableArray *slotKey = [NSMutableArray array];
			for (unsigned s = 0; s < maxSlots; s++) [slotKey addObject:[NSNull null]];
			for (NSDictionary *it in sorted) {
				float x = [it[@"x"] floatValue], y = [it[@"y"] floatValue];
				int best = -1; float bestD = MAXFLOAT;
				for (unsigned s = 0; s < maxSlots; s++) {
					if (slotKey[s] != [NSNull null]) continue;
					float d = (slotOrigin[s].x - x) * (slotOrigin[s].x - x) + (slotOrigin[s].y - y) * (slotOrigin[s].y - y);
					if (d < bestD) { bestD = d; best = (int)s; }
				}
				if (best < 0) { FGLogErr(@"convert: page full while snapping"); return NO; }
				slotKey[best] = it[@"key"];
			}
			NSMutableArray *keys = [NSMutableArray array], *gaps = [NSMutableArray array];
			int last = -1;
			for (unsigned s = 0; s < maxSlots; s++) if (slotKey[s] != [NSNull null]) last = (int)s;
			for (int s = 0; s <= last; s++) {
				if (slotKey[s] == [NSNull null]) [gaps addObject:@(s)]; else [keys addObject:slotKey[s]];
			}
			[pages addObject:@{@"icons": keys, @"gaps": gaps}];
		}
	}
	return WriteLayout(toFree ? @"free" : @"grid", pages, toFree ? free : nil);
}

static BOOL SettingEnabled(void) {
	id v = ReadSetting(@"enabled");
	return v ? [v boolValue] : YES;
}

static void HandleSettingsChange(void) {
	@try {
		if (SettingEnabled() != sEnabled) { // master switch: takes effect on the next launch
			FGLogErr(@"enabled -> %d", !sEnabled);
			Respring();
			return;
		}
		if (!sEnabled) return;
		if ([ReadSetting(@"reset") boolValue]) { // "Reset layout": back to stock, then respring
			WriteSetting(@"reset", @NO);
			[[NSFileManager defaultManager] removeItemAtPath:kLayoutPath error:nil];
			FGLogErr(@"layout reset");
			Respring();
			return;
		}
		BOOL wantFree = [ReadSetting(@"mode") isEqual:@"free"];
		if (wantFree == sFreeMode) return;
		if (ConvertLayout(wantFree)) {
			FGLogErr(@"mode -> %@, layout converted", wantFree ? @"free" : @"grid");
			Respring();
		} else {
			WriteSetting(@"mode", sFreeMode ? @"free" : @"grid"); // keep setting and layout consistent
		}
	} @catch (NSException *e) {
		FGLogErr(@"settings change threw %@: %@", e.name, e.reason);
	}
}

static void SettingsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef ui) {
	dispatch_async(dispatch_get_main_queue(), ^{ HandleSettingsChange(); });
}

#pragma mark - Startup

// Crash-loop guard: three launches in a row that don't survive 30 s AND a fresh SpringBoard crash
// report => disable ourselves. (Three quick manual resprings alone are not a crash loop.)
static BOOL CrashLoopDetected(void) {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
	NSMutableArray *ts = [NSMutableArray array];
	for (NSString *l in [[NSString stringWithContentsOfFile:kBootFile encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"]) {
		double t = [l doubleValue];
		if (t > 0 && now - t < 180) [ts addObject:@(t)];
	}
	[ts addObject:@(now)];
	[[ts componentsJoinedByString:@"\n"] writeToFile:kBootFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
	if (ts.count < 3) return NO;

	double since = [ts[ts.count - 3] doubleValue] - 5;
	NSString *dir = @"/var/mobile/Library/Logs/CrashReporter";
	for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
		if (![f hasPrefix:@"SpringBoard"] || ![f hasSuffix:@".ips"]) continue;
		NSDate *d = [[fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:f] error:nil] fileModificationDate];
		if ([d timeIntervalSince1970] > since) return YES;
	}
	return NO;
}

%ctor {
	NSFileManager *fm = [NSFileManager defaultManager];
	if ([fm fileExistsAtPath:kKillSwitch]) return; // kill switch: do nothing at all

	// Keep the log small.
	NSDictionary *la = [fm attributesOfItemAtPath:kLogPath error:nil];
	if ([la fileSize] > 64 * 1024) [fm removeItemAtPath:kLogPath error:nil];

	if (CrashLoopDetected()) {
		[@"auto-disabled after repeated crashes\n" writeToFile:kKillSwitch atomically:YES encoding:NSUTF8StringEncoding error:nil];
		[fm removeItemAtPath:kBootFile error:nil];
		FGLogErr(@"CRASH LOOP DETECTED - FreeGrid disabled itself (reinstall or delete %@ to re-enable)", kKillSwitch);
		return;
	}
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		[[NSFileManager defaultManager] removeItemAtPath:kBootFile error:nil];
	});

	sDebug = [fm fileExistsAtPath:kDebugFile];
	sEnabled = SettingEnabled();
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, SettingsChanged,
		(__bridge CFStringRef)kNotifyName, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	if (!sEnabled) { FGLogErr(@"FreeGrid is switched off in Settings"); return; } // observer stays so the switch can turn it on

	sFree = [NSMutableDictionary dictionary];
	sFreeMode = [ReadSetting(@"mode") isEqual:@"free"];
	FGLogErr(@"--- FreeGrid 1.0 loaded (mode=%@, debug=%d) ---", sFreeMode ? @"free" : @"grid", sDebug);
	%init;
}
