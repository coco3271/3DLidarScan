import SwiftUI

/// How to film a room for a sharp, complete Gaussian-splat walkthrough. Shown before the first
/// scan and from the "?" button while scanning.
struct ScanTutorial: View {
  var done: () -> Void
  @State private var page = 0

  init(done: @escaping () -> Void) { self.done = done }

  private let pages: [(symbol: String, color: Color, title: String, text: String)] = [
    ("iphone.landscape", .red, "Hold your iPhone sideways and film",
     "Scanning is landscape: every frame sees more of the room. The app records video while the LiDAR measures, and saves exactly where the phone was and which way it pointed for every frame. If you turn it upright, recording pauses until you turn it back."),
    ("tortoise.fill", .green, "Move slowly and smoothly",
     "About one small step per second, and turn slowly. Fast moves blur the video. The speed meter turns red and the phone buzzes if you go too fast. Hold the phone in front of you with both hands."),
    ("arrow.up.and.down.and.arrow.left.and.right", .blue, "Cover every angle",
     "Film each part of the room more than once: high (toward the ceiling), at eye level, and low (toward the floor). Walk around furniture, look into corners and behind doors, and get close to details you care about."),
    ("square.grid.3x3.fill", .orange, "Turn the red mesh green",
     "Red parts haven't been captured yet; green parts are. Keep filming red areas from a couple of angles until they turn green. Tap Finish to review; Resume continues the same room, Save room keeps it. Then walk to the next room without closing the app."),
    ("lightbulb.fill", .yellow, "A few tips",
     "Turn on the lights and open the blinds. Open interior doors. Mirrors, glass and TVs confuse the scanner: film them from an angle. Use the shutter for a full-resolution photo of a spot you want in the tour."),
  ]

  var body: some View {
    VStack(spacing: 0) {
      TabView(selection: $page) {
        ForEach(pages.indices, id: \.self) { i in
          let p = pages[i]
          VStack(spacing: 22) {
            Spacer()
            Image(systemName: p.symbol)
              .font(.system(size: 64, weight: .semibold))
              .foregroundStyle(p.color)
              .frame(height: 90)
            Text(p.title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(p.text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
          }
          .padding(.horizontal, 28)
          .tag(i)
        }
      }
      .tabViewStyle(.page(indexDisplayMode: .always))
      .indexViewStyle(.page(backgroundDisplayMode: .always))
      Button {
        if page < pages.count - 1 { withAnimation { page += 1 } } else { done() }
      } label: {
        Text(page < pages.count - 1 ? "Next" : "Start scanning").frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .padding(.horizontal, 24)
      .padding(.bottom, 20)
      Button("Skip", action: done).padding(.bottom, 12).opacity(page < pages.count - 1 ? 1 : 0)
    }
    .presentationDetents([.large])
    .interactiveDismissDisabled(false)
  }
}
