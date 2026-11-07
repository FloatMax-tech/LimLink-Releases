import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

val limlinkApplicationId = providers.gradleProperty("limlink.applicationId").get()

val releaseSigningFile = providers.environmentVariable("LIMLINK_SIGNING_PROPERTIES")
    .orElse("${System.getProperty("user.home")}/Library/Application Support/LimLink/Signing/release-signing.properties")
val releaseSigning = Properties().apply {
    val source = file(releaseSigningFile.get())
    if (source.isFile) source.inputStream().use { load(it) }
}
val hasReleaseSigning = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .all { !releaseSigning.getProperty(it).isNullOrBlank() }
val validateReleaseSigning = tasks.register("validateReleaseSigning") {
    doLast {
        check(hasReleaseSigning) { "Release signing is required. Set LIMLINK_SIGNING_PROPERTIES to a private signing configuration." }
        check(file(releaseSigning.getProperty("storeFile")).isFile) { "Release keystore is missing." }
    }
}
tasks.configureEach {
    if (name.startsWith("pre") && name.endsWith("ReleaseBuild")) dependsOn(validateReleaseSigning)
}

android {
    signingConfigs {
        create("officialRelease") {
            if (hasReleaseSigning) {
                storeFile = file(releaseSigning.getProperty("storeFile"))
                storePassword = releaseSigning.getProperty("storePassword")
                keyAlias = releaseSigning.getProperty("keyAlias")
                keyPassword = releaseSigning.getProperty("keyPassword")
            }
        }
    }
    namespace = "com.limlink.app"
    compileSdk = libs.versions.compileSdk.get().toInt()

    defaultConfig {
        applicationId = limlinkApplicationId
        minSdk = libs.versions.minSdk.get().toInt()
        targetSdk = libs.versions.targetSdk.get().toInt()
        versionCode = 21
        versionName = "1.0.1"
    }


    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("officialRelease")
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    lint {
        abortOnError = true
        checkReleaseBuilds = false
        error += "HardcodedText"
        // Locale resources cover the main flow; untranslated legacy strings fall back to the base locale.
        disable += "MissingTranslation"
    }
}

kotlin {
    jvmToolchain(21)
}

dependencies {
    implementation(project(":limlink-kit"))
    implementation(project(":limlink-ui"))

    val composeBom = platform(libs.compose.bom)
    implementation(composeBom)
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons.core)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.kotlinx.coroutines.android)
    testImplementation(libs.junit)
}

// Keep the existing application ID and signing identity for in-place upgrades.
android.applicationVariants.all {
    outputs.all {
        (this as com.android.build.gradle.internal.api.BaseVariantOutputImpl).outputFileName =
            "LimLink-${versionName}-Android-${buildType.name}.apk"
    }
}
