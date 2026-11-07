plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
}

android {
    namespace = "com.limlink.kit"
    compileSdk = libs.versions.compileSdk.get().toInt()

    defaultConfig {
        minSdk = libs.versions.minSdk.get().toInt()
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    lint {
        abortOnError = true
        checkReleaseBuilds = false
        error += "HardcodedText"
    }
}

kotlin {
    jvmToolchain(21)
}

dependencies {
    implementation("com.google.code.gson:gson:2.13.2")
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.documentfile)
    testImplementation(libs.junit)
}

// Independent wire probes may target the portable receiver with an explicit test PKCS12 identity.
// No test identity or automatic consent is compiled into the APK.
tasks.register<JavaExec>("interopHost") {
    dependsOn("compileDebugUnitTestKotlin")
    classpath = configurations.getByName("debugUnitTestRuntimeClasspath") + files(
        layout.buildDirectory.dir("tmp/kotlin-classes/debug"),
        layout.buildDirectory.dir("tmp/kotlin-classes/debugUnitTest"),
    )
    mainClass.set("com.limlink.kit.lan.JvmInteropHost")
    args(providers.gradleProperty("interopArgs").orElse("").map { it.split('|') }.get())
}
