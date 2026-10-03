import SwiftUI

struct ObjectForgeRootView: View {
    var body: some View {
        TabView {
            ObjectForgeMainView()
                .tabItem {
                    Label("Photo Forge", systemImage: "photo.on.rectangle")
                }

            LiDARScanModeView()
                .tabItem {
                    Label("LiDAR Scan", systemImage: "viewfinder")
                }
        }
    }
}
