// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
import SwiftUI
import Observation
#if os(macOS)
import AppKit
#endif

// One root-size catalogue and one current raster per scene. Pane copies share this cache.
@MainActor @Observable final class NightSkyCache {
 var meteorMinute: Double?
 func animate(sky:NightSky,frame:NightFrame,rise:Double,set:Double,minute:Double,sampledAt:Date) async {
  let id = UUID()
  animationID = id
  defer { if animationID == id { meteorMinute = nil } }
  func now()->Double {minute+Date().timeIntervalSince(sampledAt)/60}
  func elapsed()->Double {let r=sky.state(frame,rise:rise,set:set,minute:now()).relative;return (r>1439 ? r-1440:r)*60}
  meteorMinute=nil
  guard elapsed()<600 else{return}
  do {
   for meteor in sky.meteors {
    if elapsed()>meteor.start+meteor.duration {continue}
    if elapsed()<meteor.start {try await Task.sleep(for:.seconds(meteor.start-elapsed()))}
    while elapsed()<=meteor.start+meteor.duration {
     try Task.checkCancellation();meteorMinute=now()
     try await Task.sleep(for:.seconds(1.0/60))
    }
    meteorMinute=nil
   }
  } catch is CancellationError {
   // SwiftUI cancels the task when visibility, power or the minute changes.
  } catch {
   assertionFailure("Unexpected meteor clock error: \(error)")
  }
 }
 @ObservationIgnored private var animationID = UUID()
 @ObservationIgnored private var size = CGSize.zero
 @ObservationIgnored private var sky: NightSky?
 @ObservationIgnored private var key = ""
 @ObservationIgnored private var cached: CGImage?
 func engine(_ size: CGSize) -> NightSky {
  if self.size != size {self.size=size;sky=NightSky(width:size.width,height:size.height);key="";cached=nil}
  return sky!
 }
 func image(size:CGSize,scale:Double,frame:NightFrame,rise:Double,set:Double,minute:Double,dark:Bool,still:Bool,watch:Bool)->CGImage {
  let sky=engine(size)
  let next="\(scale):\(minute):\(rise):\(set):\(dark):\(still):\(watch):\(frame.weight):\(frame.night)"
  if next != key {
   let ctx=NightSky.context(Int(ceil(size.width*scale)),Int(ceil(size.height*scale)));ctx.scaleBy(x:scale,y:scale)
   sky.paintStatic(ctx,frame:frame,rise:rise,set:set,minute:minute,dark:dark,still:still,watch:watch)
   cached=ctx.makeImage()!;key=next
  }
  return cached!
 }
}

struct NightMinuteSchedule: TimelineSchedule {
 let visible: Bool
 func entries(from startDate:Date,mode:TimelineScheduleMode)->AnySequence<Date> {
  visible ? AnySequence(EveryMinuteTimelineSchedule().entries(from:startDate,mode:mode)) : AnySequence([startDate])
 }
}

struct NightSkyView: View {
 let cache: NightSkyCache
 let size: CGSize
 let frame: NightFrame
 let rise: Double, set: Double, minute: Double
 let dark: Bool, watch: Bool, visible: Bool
 var ownsClock: Bool = true
 var sampledMinute: Double? = nil
 var sampledAt: Date = Date()
 @Environment(\.displayScale) private var scale
 @Environment(\.accessibilityReduceMotion) private var reduceMotion
 @State private var lowPower=ProcessInfo.processInfo.isLowPowerModeEnabled
 var body: some View {
  let still=watch || reduceMotion || lowPower
  Group {
   if visible && frame.night>0 && size.width>0 && size.height>0 {
    let sky=cache.engine(size)
    let image=cache.image(size:size,scale:scale,frame:frame,rise:rise,set:set,minute:minute,dark:dark,still:still,watch:watch)
    ZStack(alignment:.topLeading) {
     Image(decorative:image,scale:scale).resizable().frame(width:size.width,height:size.height)
     if !still {
      NightMeteorView(cache:cache,sky:sky,frame:frame,rise:rise,set:set,dark:dark,sampledMinute:sampledMinute)
      if ownsClock && sampledMinute == nil {NightSkyClock(cache:cache,size:size,frame:frame,rise:rise,set:set,minute:minute,sampledAt:sampledAt,visible:visible)}

     }
    }
   }
  }
  .frame(width:size.width,height:size.height,alignment:.topLeading)
  .allowsHitTesting(false).accessibilityHidden(true)
  .onReceive(NotificationCenter.default.publisher(for:.NSProcessInfoPowerStateDidChange)) {_ in lowPower=ProcessInfo.processInfo.isLowPowerModeEnabled}
 }
}

// One root owns this task; clipped painters only observe the shared sample.
struct NightSkyClock: View {
 let cache:NightSkyCache,size:CGSize,frame:NightFrame
 let rise:Double,set:Double,minute:Double,sampledAt:Date,visible:Bool
 @Environment(\.accessibilityReduceMotion) private var reduceMotion
 @State private var lowPower=ProcessInfo.processInfo.isLowPowerModeEnabled
 var body:some View {
  Color.clear.frame(width:0,height:0)
   .task(id:"\(minute):\(rise):\(set):\(visible):\(reduceMotion):\(lowPower):\(size)") {
    if visible && !reduceMotion && !lowPower && frame.night>0 && size.width>0 && size.height>0 {
     await cache.animate(sky:cache.engine(size),frame:frame,rise:rise,set:set,minute:minute,sampledAt:sampledAt)
    } else {cache.meteorMinute=nil}
   }
   .onReceive(NotificationCenter.default.publisher(for:.NSProcessInfoPowerStateDidChange)) {_ in lowPower=ProcessInfo.processInfo.isLowPowerModeEnabled}
 }
}

private struct NightMeteorView: View {
 let cache:NightSkyCache
 let sky:NightSky, frame:NightFrame
 let rise:Double,set:Double
 let dark:Bool
 let sampledMinute:Double?
 var body:some View {
  Group {
   if let m=sampledMinute ?? cache.meteorMinute {
     Canvas { ctx,_ in
      let ns=sky.state(frame,rise:rise,set:set,minute:m)
      let centre=sky.point(0.5),rad=sky.rotate(centre.x,centre.y,ns.angle),sec=ns.relative*60
      for meteor in sky.meteors {
       let t=(sec-meteor.start)/meteor.duration
       if t>=0 && t<=1 {
        let dir=Double(-90+36*meteor.beam)*Double.pi/180,r=sky.radius*6.5/13.5*(0.25+0.4*(meteor.offset-1.05)),ux=cos(dir),uy=sin(dir)
        let head=NightSky.smooth(t)*meteor.length,tail=min(head,meteor.length*0.42),alpha=(dark ? 0.95:0.98)*sin(Double.pi*min(1,t*1.1))*meteor.brightness
        let end=CGPoint(x:rad.x+(r+head)*ux,y:rad.y+(r+head)*uy),start=CGPoint(x:end.x-tail*ux,y:end.y-tail*uy)
        let color=Color(cgColor:NightSky.color(dark ? 0xFCF3E4:0xFFFFFF,alpha))
        var path=Path();path.move(to:start);path.addLine(to:end)
        ctx.stroke(path,with:.linearGradient(Gradient(colors:[color.opacity(0),color]),startPoint:start,endPoint:end),style:StrokeStyle(lineWidth:1.4,lineCap:.round))
        ctx.fill(Path(ellipseIn:CGRect(x:end.x-1.1,y:end.y-1.1,width:2.2,height:2.2)),with:.color(color))
       }
      }
     }
   }
  }
 }
}

#if os(macOS)
// Occlusion belongs to the window, not app focus. An unfocused visible window still draws.
struct NightWindowVisibility: NSViewRepresentable {
 @Binding var visible:Bool
 func makeNSView(context:Context)->Probe {let v=Probe();v.changed={visible=$0};return v}
 func updateNSView(_ view:Probe,context:Context) {}
 static func dismantleNSView(_ view:Probe,coordinator:()){view.stop()}
 final class Probe:NSView {
  var changed:((Bool)->Void)?
  private var tokens:[NSObjectProtocol]=[]
  override func viewDidMoveToWindow(){super.viewDidMoveToWindow();tokens.forEach(NotificationCenter.default.removeObserver);tokens=[]
   if let window {
    for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,NSWindow.willCloseNotification] {
     tokens.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main){[weak self] _ in MainActor.assumeIsolated{self?.refresh()}})
    }
   }
   refresh()
  }
  func refresh(){let shown=window.map{$0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)} ?? false;Task { @MainActor [weak self] in self?.changed?(shown) }}
  func stop(){tokens.forEach(NotificationCenter.default.removeObserver);tokens=[];changed=nil}
 }
}
#endif
