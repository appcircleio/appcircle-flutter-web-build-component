# Appcircle Flutter Web Build

This component builds a web app with the [Flutter SDK](https://flutter.dev/docs/deployment/web#building-the-app-for-release).

Required Input Variables

- $AC_FLUTTER_PROJECT_DIR: The root directory of your Flutter project where pubspec.yaml file exist.

Output Variables

- $AC_FLUTTER_WEB_PATH: Path for the generated web app

## Running tests

Requires the [RSpec](https://rspec.info) gem and the Ruby standard library (Coverage, Open3). No Gemfile or Bundler needed.

```bash
ruby test/test_main.rb
```

The tests never run the real Flutter SDK: the subprocess cases execute the step inside a temp directory with a stub `flutter` executable on `PATH` that records the arguments and working directory it was called with and writes a fake `build/web` tree, and assert the composed `flutter config --enable-web` / `flutter build web` commands, the copy into `$AC_OUTPUT_DIR/web` and the exported `AC_FLUTTER_WEB_PATH`. A coverage report for `main.rb` is printed at the end of each run.
