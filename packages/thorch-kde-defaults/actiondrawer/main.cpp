// SPDX-FileCopyrightText: 2026 Thorch contributors
// SPDX-License-Identifier: GPL-2.0-or-later

#include <QGuiApplication>
#include <QLockFile>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QScreen>
#include <QStandardPaths>
#include <QString>
#include <QStringList>

#include <cstdlib>

namespace
{
bool environmentContainsToken(const char *name, const QString &expectedToken)
{
    const QStringList tokens =
        qEnvironmentVariable(name).split(QLatin1Char(':'), Qt::SkipEmptyParts);
    return tokens.contains(expectedToken, Qt::CaseInsensitive);
}

QScreen *controlScreen()
{
    const auto screens = QGuiApplication::screens();
    for (QScreen *screen : screens) {
        if (screen->name() == QStringLiteral("DSI-1")) {
            return screen;
        }
    }
    return nullptr;
}
}

int main(int argc, char *argv[])
{
    QGuiApplication application(argc, argv);
    application.setApplicationName(QStringLiteral("Thorch Desktop Action Drawer"));
    application.setDesktopFileName(QStringLiteral("org.thorch.DesktopActionDrawer"));
    application.setOrganizationName(QStringLiteral("Thorch"));

    if (environmentContainsToken("XDG_SESSION_DESKTOP", QStringLiteral("plasma-mobile"))
        || environmentContainsToken("PLASMA_PLATFORM", QStringLiteral("phone"))
        || environmentContainsToken("PLASMA_PLATFORM", QStringLiteral("mobile"))) {
        // Plasma Mobile owns the action drawer in a mobile session.
        return 0;
    }

    QLockFile instanceLock(QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation)
                           + QStringLiteral("/thorch-desktop-action-drawer.lock"));
    if (!instanceLock.tryLock(0)) {
        return 0;
    }

    if (!qEnvironmentVariableIsSet("QT_QUICK_CONTROLS_STYLE")) {
        qputenv("QT_QUICK_CONTROLS_STYLE", "org.kde.desktop");
    }

    QQmlApplicationEngine engine;
    const auto refreshControlScreen = [&engine]() {
        // Qt.application.screens exposes QQuickScreenInfo objects to QML, but
        // Window.screen and LayerShell.Window.screen require a QScreen. Export
        // the native object explicitly so both windows bind to the real output.
        engine.rootContext()->setContextProperty(QStringLiteral("thorchControlScreen"), controlScreen());
    };
    refreshControlScreen();
    QObject::connect(&application,
                     &QGuiApplication::screenAdded,
                     &engine,
                     [refreshControlScreen](QScreen *) { refreshControlScreen(); });
    QObject::connect(&application,
                     &QGuiApplication::screenRemoved,
                     &engine,
                     [refreshControlScreen](QScreen *) { refreshControlScreen(); });
    QObject::connect(&engine,
                     &QQmlApplicationEngine::objectCreationFailed,
                     &application,
                     []() { QCoreApplication::exit(EXIT_FAILURE); },
                     Qt::QueuedConnection);
    engine.loadFromModule(QStringLiteral("org.thorch.desktopactiondrawer"), QStringLiteral("Main"));

    return application.exec();
}
