import SwiftUI
import YiyeKit

/// 设置：镜像文件夹、字号、大管家、中文 / English、版本号
struct SettingsScreen: View {
    @Environment(AppModel.self) private var app
    @State private var showPicker = false

    private var t: Lang { app.lang }

    var body: some View {
        @Bindable var settings = app.settings
        VStack(spacing: 0) {
            SmartBar {
                Button { if !app.path.isEmpty { app.path.removeLast() } } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                        Text(t.t("editor.back"))
                    }
                }
                .buttonStyle(SmartButtonStyle())
            } center: {
                BarTitle(text: t.t("settings.title"))
            } right: {
                EmptyView()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section(t.t("settings.mirror")) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: app.mirror.isOn ? "icloud" : "icloud.slash")
                                    .foregroundStyle(Color(app.mirror.isOn ? Ink.accent : Ink.text3))
                                Text(app.mirror.displayPath(t))
                                    .font(.system(size: 16))
                                    .foregroundStyle(Color(Ink.text))
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Button(app.mirror.isOn ? t.t("settings.mirrorChange") : t.t("mirror.choose")) { showPicker = true }
                                    .buttonStyle(SmartButtonStyle())
                            }
                            Text(t.t("settings.mirrorNote"))
                                .font(.system(size: 13))
                                .foregroundStyle(Color(Ink.text3))
                                .fixedSize(horizontal: false, vertical: true)
                            if app.mirror.isOn {
                                Button { app.mirror.importAll(into: app) } label: {
                                    Label(t.t("settings.import"), systemImage: "tray.and.arrow.down")
                                }
                                .buttonStyle(PlainTextButtonStyle())
                            }
                        }
                    }

                    section(t.t("settings.fontSize")) {
                        Segmented(items: [(0, t.t("font.small")), (1, t.t("font.medium")), (2, t.t("font.large"))], selection: $settings.fontSize)
                    }

                    section(t.t("settings.voice")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Segmented(items: [("zh-CN", "中文"), ("en-US", "English")], selection: $settings.voiceLang)
                            Text(t.t("settings.voiceNote"))
                                .font(.system(size: 13))
                                .foregroundStyle(Color(Ink.text3))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    section(t.t("settings.butler")) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Circle().fill(Color(presenceColor)).frame(width: 9, height: 9)
                                Text(presenceText).font(.system(size: 16)).foregroundStyle(Color(Ink.text))
                                Spacer()
                            }
                            .frame(minHeight: 32)
                            Toggle(isOn: $settings.butlerAutoPhoto) {
                                Text(t.t("settings.butlerAuto")).font(.system(size: 16)).foregroundStyle(Color(Ink.text))
                            }
                            .tint(Color(Ink.accent))
                            .frame(minHeight: 44)
                            Text(t.t("settings.butlerNote"))
                                .font(.system(size: 13))
                                .foregroundStyle(Color(Ink.text3))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    section(t.t("settings.language")) {
                        Segmented(items: [("system", t.t("lang.system")), ("zh-Hans", "中文"), ("en", "English")],
                                  selection: Binding(get: { app.lang.choice }, set: { app.lang.set($0) }))
                    }

                    section(t.t("settings.version")) {
                        HStack {
                            Text("\(ButlerService.appVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
                                .font(.system(size: 16).monospacedDigit())
                                .foregroundStyle(Color(Ink.text))
                            Spacer()
                            Text(t.t("app.name")).font(.system(size: 13)).foregroundStyle(Color(Ink.text3))
                        }
                        .frame(minHeight: 32)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(PaperBackground().ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showPicker) {
            FolderPickerView { url in
                showPicker = false
                guard let url else { return }
                do {
                    try app.mirror.use(url)
                    app.settings.mirrorAsked = true
                    app.showMirrorPrompt = false
                    for n in app.allNotes() where !n.trashed { app.mirror.saveNow(n, attachments: app.attachments) }
                    app.show(t.f("mirror.on", app.mirror.displayPath(t)))
                } catch {
                    app.show(t.f("mirror.failed", error.localizedDescription))
                }
            }
            .ignoresSafeArea()
        }
        .onAppear { app.butler.look() }
    }

    private var presenceText: String {
        guard app.mirror.isOn else { return t.t("butler.needMirrorShort") }
        switch app.butler.presence {
        case .never: return t.t("butler.absent")
        case .online: return t.t("butler.online")
        case .seen(let m, _): return t.f("butler.seen", m)
        }
    }

    private var presenceColor: UIColor {
        switch app.butler.presence {
        case .online: return .dyn(0x34C759, 0x30D158)
        case .seen(_, let off): return off ? Ink.text3 : .dyn(0xFF9F0A, 0xFFD60A)
        case .never: return Ink.text3
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(Ink.text3))
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(Ink.rule)).frame(height: 0.75).padding(.horizontal, 20)
        }
    }
}
