# Medico OPD Assistant - Client Application

An AI-assisted outpatient consultation assistant tailored for medical doctors and clinics in India. This repository contains the cross-platform Flutter client application targeting Android and iOS, backed by Supabase.

---

## 🚀 Current Project Status
- **Phase**: `PHASE-000: Project Foundation & Scaffolding`
- **Task**: `TASK-000-01`
- **Status**: Skeleton scaffold complete. Supabase connection framework established with runtime `.env` secret isolation. No clinical logic, auth screens, or database tables are present in this initial phase.

---

## 🛠️ Prerequisites & Setup

### 1. Flutter Toolchain
- **Flutter SDK**: 3.47.x (Channel `stable`)
- **Dart SDK**: 3.13.x
- Verify your environment:
  ```bash
  flutter doctor
  ```

### 2. Environment Variables & Secret Configuration
Secrets and backend API endpoints must **never** be hardcoded or checked into source control.

1. Duplicate `.env.example` to create your local `.env`:
   ```bash
   cp .env.example .env
   ```
2. Populate `.env` with your Supabase credentials:
   ```env
   # Production application
   SUPABASE_URL=https://your-production-project.supabase.co
   SUPABASE_ANON_KEY=your-actual-anon-key

   # Isolated test project (Required for running adversarial RLS tests)
   SUPABASE_TEST_URL=https://your-test-project.supabase.co
   SUPABASE_TEST_ANON_KEY=your-test-anon-key
   SUPABASE_TEST_SERVICE_ROLE_KEY=your-test-service-role-key
   ```
   > **Inviolable Security Rule**: Tests **NEVER** run against the production database. All multi-tenant, adversarial, and integration test suites strictly require an isolated test instance (e.g. `medico-opd-test`). An active compile-time/runtime production guard immediately blocks test execution if `SUPABASE_TEST_URL` points to production.


---

## 📱 Running the Application

### Install Dependencies
```bash
flutter pub get
```

### Run on Android
Launch an Android emulator or connect a physical device, then execute:
```bash
flutter run -d android
```

### Run on iOS
> *Note: iOS compilation and simulator execution require macOS and Xcode.*
```bash
flutter run -d ios
```

---

## 🧪 Verification & Testing

### Static Analysis
Ensure code meets strict formatting and linting rules:
```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
```

### Automated Tests
Run unit and widget smoke tests:
```bash
flutter test
```

---

## 🔄 Continuous Integration (CI)

A GitHub Actions pipeline is configured at [`.github/workflows/ci.yml`](.github/workflows/ci.yml) and runs on all pushes and pull requests to `main` and `master`:
1. **`analyze-and-test`** (Ubuntu): Sets up Java 17 and Flutter, creates `.env` from `.env.example`, checks `dart format`, runs `flutter analyze`, and executes `flutter test`.
2. **`build-android`** (Ubuntu): Verifies that an Android debug APK (`flutter build apk --debug`) compiles without errors.
3. **`build-ios`** (macOS): Verifies that the iOS target compiles on macOS (`flutter build ios --config-only --no-codesign`).

---

## 📖 Architecture & Living Context

For a detailed architecture overview, running changelog, design rationales, system diagram, and "Do Not Break" rules, refer to [**`PROJECT_CONTEXT.md`**](PROJECT_CONTEXT.md).
