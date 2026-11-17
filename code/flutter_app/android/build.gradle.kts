allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // flutter_js 0.8.7 的 android/build.gradle 把 Kotlin 的 jvmTarget 写死成
    // JavaVersion.VERSION_1_8，而 AGP 9 给 JavaCompile 的是 11。Gradle 9 会
    // 因为两者不一致直接判 :flutter_js:compileReleaseKotlin 失败：
    //
    //   Inconsistent JVM-target compatibility detected for tasks
    //   'compileReleaseJavaWithJavac' (11) and 'compileReleaseKotlin' (1.8).
    //
    // 不去改 pub cache 里的第三方源码（`flutter pub get` 会把它覆盖回去），
    // 在工程层把这一个子项目的 Kotlin 目标抬到 11，与 Java 侧对齐。
    // 只对 flutter_js 生效，app 与 media_kit 等其他插件不受影响。
    if (name == "flutter_js") {
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
