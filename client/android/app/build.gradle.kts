import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Calculate version code from semantic version and build number
// Formula: (major * 10000) + (minor * 100) + (patch * 10) + buildNumber
// Example: 1.1.1+10 -> (1*10000) + (1*100) + (1*10) + 10 = 10120
fun calculateVersionCode(versionName: String): Int {
    val parts = versionName.split("+")
    if (parts.size != 2) {
        println("Warning: Invalid version format '$versionName', using version code 1")
        return 1
    }
    
    val version = parts[0].split(".")
    if (version.size != 3) {
        println("Warning: Invalid semantic version '$parts[0]', using version code 1")
        return 1
    }
    
    val major = version[0].toIntOrNull() ?: 0
    val minor = version[1].toIntOrNull() ?: 0
    val patch = version[2].toIntOrNull() ?: 0
    val buildNumber = parts[1].toIntOrNull() ?: 0
    
    val calculatedCode = (major * 10000) + (minor * 100) + (patch * 10) + buildNumber
    println("Calculated version code: $calculatedCode from version $versionName")
    return calculatedCode
}

// Load keystore properties
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "org.peerwave.client"
    compileSdk = 36  // Required by plugins (flutter_webrtc, livekit_client, etc.)
    // ndkVersion removed - not required for this project

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.peerwave.client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion  // Android 5.0 Lollipop
        targetSdk = 36  // Match compileSdk
        
        // Calculate version code from semantic version + build number
        // This ensures unique, incrementing version codes for Google Play
        val flutterVersionName = flutter.versionName ?: "1.0.0+1"
        versionCode = calculateVersionCode(flutterVersionName)
        versionName = flutterVersionName.split("+")[0]  // Display version without build number
        
        // Enable multidex for apps with many dependencies
        multiDexEnabled = true
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
        }
        release {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = true
            isShrinkResources = true
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// Disable incremental compilation to fix cross-drive path issues
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    incremental = false
}
