# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(zhuiju LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "zhuiju")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === 修复 jni 插件的 /DELAYLOAD 未生效问题 ===
# jni/src/CMakeLists.txt 里写的是：
#   if(WIN32)
#     set_target_properties(${TARGET_NAME} PROPERTIES LINK_FLAGS "/DELAYLOAD:jvm.dll")
#   endif()
# 但 ${TARGET_NAME} 在该文件中从未定义（真正的 target 名是 `jni`），所以这条
# 指令静默失效，jvm.dll 进了 dartjni.dll 的【普通导入表】而非延迟加载表。
# 后果：任何没装 JDK 的机器一加载 dartjni.dll 就会失败。
# 这里在应用层补上，且用 TARGET 存在性判断包一层，插件将来自己修好了也不冲突。
if(WIN32 AND TARGET jni)
  target_link_options(jni PRIVATE "/DELAYLOAD:jvm.dll")
  # 插件用的是 plain signature（target_link_libraries(jni ${JNI_LIBRARIES})），
  # CMake 不允许同一 target 混用 plain / keyword 两种写法，这里必须跟随 plain。
  target_link_libraries(jni delayimp)
endif()


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
#
# 路径有两个候选，必须都看一眼：这是模板原文写死的旧位置，而新版 Flutter
# 把 native_assets.json 放到了 runner 的构建输出目录下。v1.11.4 打包时
# 就因为这里只认旧位置，`cmake --install` 静默漏掉了这个文件 —— 旧的
# install(DIRECTORY) 在源目录不存在时不报错，只是什么都不做。
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
# === VC++ 运行时 ===
#
# 为什么必须打包 CRT：`zhuiju.exe` 的导入表里写死了
# MSVCP140.dll / VCRUNTIME140.dll / VCRUNTIME140_1.dll（Flutter 默认
# /MD 动态链接）。这三条是**加载期**依赖，缺一个进程就起不来，报的是
# 「找不到 MSVCP140.dll」——用户只会觉得「解压了双击没反应」。
#
# 2026-11-13 的真实事故：v1.11.2 重打包后 zip 从 34 个文件掉到 25 个，
# 少的 10 个正是这些 CRT dll。原因是上一版是手工把 dll 复制进
# Release 目录再打包的，构建流程本身从来没产出过它们；一旦清掉
# build 目录重新构建，就悄悄少了，而打包脚本只检查
# exe / flutter_windows.dll / data/app.so 三件，检查不出来。
#
# 改成由 CMake 自己带上后，`cmake --install` 每次都会把这批 dll 铺到
# 输出目录，不再依赖谁记得手工复制。
#
# 用 SKIP + 自行 install 的原因：模块默认的 install 目标是 bin/ 子目录，
# 而 Flutter 的产物是「所有 dll 平铺在 exe 旁边」，放错位置等于没放。
set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
include(InstallRequiredSystemLibraries)
if(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS)
  install(FILES ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS}
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# 旧位置（模板原文）。通常不存在，但保留：个别 Flutter 版本仍会把
# 原生资产的 dll 放在这儿，存在就必须带上，否则运行期找不到。
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# 新位置：native_assets.json 由 flutter assemble 产在 **Flutter 自己的构建树**
# 里，即 `${PROJECT_BUILD_DIR}windows/x64/runner/<Config>/`。
#
# 这里踩过两次路径错误，都记下来免得再犯：
#   1. `CMAKE_BINARY_DIR` → build/win_cmake，那是 CMake 的树，
#      和 Flutter 的 build/windows/... 是两棵完全不同的目录；
#   2. `$<TARGET_FILE_DIR:zhuiju>` → 同样落在 build/win_cmake/runner/Release，
#      因为 CMake 只认自己生成的可执行文件位置。
# 唯一正确的位置是 Flutter assemble 的输出，也就是下面这条拼法。
#
# 不用 install(FILES)：它要求文件在**配置阶段**就存在，而这个文件是构建
# 阶段才生成的。用 install(CODE) 在安装期判断，缺失时明确告警而不是
# 静默少文件；「安装目录 == 构建输出目录」时也能正确跳过，不会自己拷自己。
install(CODE "
  set(_na_src \"${PROJECT_BUILD_DIR}windows/x64/runner/\${CMAKE_INSTALL_CONFIG_NAME}/native_assets.json\")
  if(EXISTS \"\${_na_src}\")
    file(COPY \"\${_na_src}\" DESTINATION \"\${CMAKE_INSTALL_PREFIX}\")
    message(STATUS \"Installing: \${_na_src}\")
  else()
    message(WARNING \"native_assets.json 不存在：\${_na_src}，产物会缺这个文件\")
  endif()
" COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
