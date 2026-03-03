@echo off
SETLOCAL
SET pubspec_yaml_path=C:\flutter\packages\flutter_tools\pubspec.yaml
SET pubspec_lock_path=C:\flutter\packages\flutter_tools\pubspec.lock
FOR /F %%i IN ('DIR /B /O:D "%pubspec_yaml_path%" "%pubspec_lock_path%"') DO ECHO %%i
