cmake_minimum_required(VERSION 3.16)

project(thorch-kde-defaults VERSION 1.0.0)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(ECM 6.0 REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})

include(KDEInstallDirs)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick)
find_package(KF6 REQUIRED COMPONENTS CoreAddons KCMUtils)

qt_policy(SET QTP0001 NEW)

add_subdirectory(kcm)
add_subdirectory(actiondrawer)
