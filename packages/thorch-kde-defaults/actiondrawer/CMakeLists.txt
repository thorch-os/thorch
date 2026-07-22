add_executable(thorch-desktop-action-drawer
    main.cpp
)

qt_add_qml_module(thorch-desktop-action-drawer
    URI org.thorch.desktopactiondrawer
    VERSION 1.0
    QML_FILES
        Main.qml
)

target_link_libraries(thorch-desktop-action-drawer PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Quick
)

install(TARGETS thorch-desktop-action-drawer
    RUNTIME DESTINATION ${KDE_INSTALL_LIBDIR}
)
