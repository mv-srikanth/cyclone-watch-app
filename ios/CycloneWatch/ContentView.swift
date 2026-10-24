import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = WebModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        DashboardWebView(model: model)
            .ignoresSafeArea(.container, edges: .bottom)
            .background(Color(red: 11 / 255, green: 22 / 255, blue: 34 / 255).ignoresSafeArea())
            .fullScreenCover(isPresented: $model.showFilm) {
                FilmView(isPresented: $model.showFilm)
            }
            .sheet(item: $model.shareItem) { item in
                ShareSheet(items: [item.url])
            }
            .onAppear {
                Notifications.requestPermission()
            }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .background:
                    AppDelegate.scheduleRefresh()
                case .active:
                    // pick up anything the background check recorded while the app was closed
                    model.web?.evaluateJavaScript("window.__cwSetPrefs && window.__cwSetPrefs(\(Prefs.pageJSON()))")
                default:
                    break
                }
            }
    }
}

/// Plays the track animation full screen.
struct FilmView: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 5 / 255, green: 13 / 255, blue: 21 / 255).ignoresSafeArea()
            FilmWebView()
                .ignoresSafeArea(.container, edges: .bottom)
            Button {
                isPresented = false
            } label: {
                Label("Close", systemImage: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.leading, 12)
            .padding(.top, 6)
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// System share sheet: "Open in Google Earth", Save to Files, AirDrop and so on.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
