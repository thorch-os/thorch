kcmutils_add_qml_kcm(kcm_thorch_hardware SOURCES thorchhardwarekcm.cpp)

target_link_libraries(kcm_thorch_hardware PRIVATE
    Qt::Core
    KF6::CoreAddons
    KF6::KCMUtilsQuick
)
