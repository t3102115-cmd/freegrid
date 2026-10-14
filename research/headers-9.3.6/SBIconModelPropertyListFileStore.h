@interface SBIconModelPropertyListFileStore : NSObject
  ivar _currentIconStateURL  @"NSURL"
  ivar _desiredIconStateURL  @"NSURL"
  @property currentIconStateURL  T@"NSURL",&,N,V_currentIconStateURL
  @property desiredIconStateURL  T@"NSURL",&,N,V_desiredIconStateURL
  @property hash  TI,R
  @property superclass  T#,R
  @property description  T@"NSString",R,C
  @property debugDescription  T@"NSString",R,C
- saveCurrentIconState:error:  c16@0:4@8^@12
- saveDesiredIconState:error:  c16@0:4@8^@12
- deleteCurrentIconState:  c12@0:4^@8
- deleteDesiredIconState:  c12@0:4^@8
- loadCurrentIconState:  @12@0:4^@8
- loadDesiredIconState:  @12@0:4^@8
- _load:error:  @16@0:4@8^@12
- _delete:error:  c16@0:4@8^@12
- _save:url:error:  c20@0:4@8@12^@16
- .cxx_destruct  v8@0:4
- currentIconStateURL  @8@0:4
- setCurrentIconStateURL:  v12@0:4@8
- desiredIconStateURL  @8@0:4
- setDesiredIconStateURL:  v12@0:4@8
@end
