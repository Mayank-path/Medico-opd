import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load release keystore configuration from android/key.properties or environment variables
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.medico.opd.medico_opd"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.medico.opd.medico_opd"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val keyAliasProp = keystoreProperties.getProperty("keyAlias") ?: System.getenv("ANDROID_KEY_ALIAS")
            val keyPasswordProp = keystoreProperties.getProperty("keyPassword") ?: System.getenv("ANDROID_KEY_PASSWORD")
            val storeFilePath = keystoreProperties.getProperty("storeFile") ?: System.getenv("ANDROID_STORE_FILE")
            val storePasswordProp = keystoreProperties.getProperty("storePassword") ?: System.getenv("ANDROID_STORE_PASSWORD")

            val hasAnyConfig = !keyAliasProp.isNullOrBlank() ||
                               !keyPasswordProp.isNullOrBlank() ||
                               !storeFilePath.isNullOrBlank() ||
                               !storePasswordProp.isNullOrBlank()

            if (hasAnyConfig) {
                if (keyAliasProp.isNullOrBlank() ||
                    keyPasswordProp.isNullOrBlank() ||
                    storeFilePath.isNullOrBlank() ||
                    storePasswordProp.isNullOrBlank()
                ) {
                    throw GradleException(
                        "Incomplete Android release signing configuration. All 4 parameters must be provided:\n" +
                        "storeFile, storePassword, keyAlias, keyPassword (via key.properties or ANDROID_* environment variables)."
                    )
                }

                val candidateFile = file(storeFilePath)
                val resolvedStoreFile = if (candidateFile.isAbsolute) candidateFile else rootProject.file(storeFilePath)

                if (!resolvedStoreFile.exists()) {
                    throw GradleException(
                        "Android release keystore file not found at: ${resolvedStoreFile.absolutePath}.\n" +
                        "Ensure the keystore path in key.properties or ANDROID_STORE_FILE exists."
                    )
                }

                keyAlias = keyAliasProp
                keyPassword = keyPasswordProp
                storeFile = resolvedStoreFile
                storePassword = storePasswordProp
            }
            // If release signing properties are absent, storeFile remains unconfigured (null).
            // When building release, Android Gradle Plugin fails validateSigningRelease rather than
            // silently falling back to debug signing.
        }
    }

    buildTypes {
        release {
            // Production signing configuration: strictly decoupled from debug keys.
            // Release builds must NEVER be signed with debug keystore.
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
}
