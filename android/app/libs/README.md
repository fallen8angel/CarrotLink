# ExecuTorch Local AAR Drop-In

Place a backend-specific `executorch.aar` here when testing local Android runtime builds.

Expected path:

- `android/app/libs/executorch.aar`

Build with:

```powershell
cd E:\Carrot\CarrotLink\android
.\gradlew.bat :app:assembleDebug
```

If you need to force the old Maven path:

```powershell
.\gradlew.bat :app:assembleDebug -PuseLocalAar=false
```

Reference:

- [Using ExecuTorch on Android](https://docs.pytorch.org/executorch/stable/using-executorch-android.html)
