plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
}

subprojects {
    tasks.register("noChineseInMainKotlin") {
        val root = project.projectDir
        doLast {
            val src = root.resolve("src/main")
            if (!src.exists()) return@doLast
            val pattern = Regex("[\\u4e00-\\u9fff]")
            val hits = mutableListOf<String>()
            src.walkTopDown()
                .filter { it.isFile && it.extension == "kt" }
                .forEach { file ->
                    file.readLines().forEachIndexed { index, line ->
                        if (pattern.containsMatchIn(line)) {
                            hits += "${file.relativeTo(root)}:${index + 1}: $line"
                        }
                    }
                }
            if (hits.isNotEmpty()) {
                error(
                    "Chinese text belongs in res/values/strings.xml:\n" +
                        hits.joinToString("\n"),
                )
            }
        }
    }
    tasks.matching { it.name == "check" }.configureEach {
        dependsOn("noChineseInMainKotlin")
    }
}
