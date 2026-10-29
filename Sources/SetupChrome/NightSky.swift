// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
import Foundation
import CoreGraphics
#if !os(watchOS)
import CoreImage
#endif

// A small native port, shared verbatim by the two Swift source trees.
// Coordinates are logical points in the root scene, never an individual split pane.
struct NightGlow { let x: Double; let y: Double; let radius: Double; let alpha: Double }
struct NightFrame { let t: Double; let night: Double; let weight: Double; let glows: [NightGlow] }
struct NightState { let stars: Double; let angle: Double; let aurora: Double; let relative: Double; let midnight: Double }
struct NightStar { let x: Double; let y: Double; let level: Int }
struct NightMeteor { let start: Double; let duration: Double; let beam: Int; let offset: Double; let length: Double; let brightness: Double }
struct NightRandom {
 var seed: UInt32
 mutating func next() -> Double {
  seed = seed &+ 0x6D2B79F5
  var t = (seed ^ (seed >> 15)) &* (1 | seed)
  t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
  return Double(t ^ (t >> 14)) / 4294967296
 }
}
final class NightSky {
 static let phi = (1 + sqrt(5.0)) / 2
 let width: Double, height: Double, side: Double, radius: Double, arcRadius: Double, ox: Double, oy: Double, a0: Double, sweep: Double
 let stars: [NightStar], meteors: [NightMeteor]
 #if !os(watchOS)
 private lazy var imageContext = CIContext(options: [.useSoftwareRenderer: true])
 #endif
 static func smooth(_ x: Double) -> Double { let a = min(1,max(0,x));return a*a*(3-2*a) }
 static func wrap(_ x: Double) -> Double { (x.truncatingRemainder(dividingBy:1440)+1440).truncatingRemainder(dividingBy:1440) }
 static func hash(_ a: Double,_ b: Double) -> Double { let x=sin(a*12.9898+b*78.233)*43758.5453;return x-floor(x) }
 init(width: Double,height: Double) {
  self.width=width;self.height=height;side=min(width,height);radius=Self.phi*side/2
  let d=radius/sqrt(2.0),dx=width+2*d,dy=height+2*d,c=hypot(dx,dy),s=tan(Double.pi/20)/2*c
  arcRadius=c*c/(8*s)+s/2;ox=width/2-dy/c*(arcRadius-s);oy=height/2+dx/c*(arcRadius-s)
  a0=atan2(-d-oy,-d-ox);var delta=atan2(height+d-oy,width+d-ox)-a0
  while delta > .pi { delta -= 2 * .pi };while delta < -.pi { delta += 2 * .pi };sweep=delta
  var lo=Double.infinity,hi=0.0,ta=Double.infinity,tb = -Double.infinity
  for i in 0...400 {
   let f=Double(i)/100;let x:Double,y:Double
   if f<1 {x=f*width;y=0} else if f<2 {x=width;y=(f-1)*height} else if f<3 {x=(3-f)*width;y=height} else {x=0;y=(4-f)*height}
   let dx=x-ox,dy=y-oy,r=hypot(dx,dy);var t=atan2(dy,dx)
   while t-a0 > .pi {t -= 2 * .pi};while t-a0 < -.pi {t += 2 * .pi}
   lo=min(lo,r);hi=max(hi,r);ta=min(ta,t);tb=max(tb,t)
  }
  ta -= abs(sweep)/2+0.01;tb += abs(sweep)/2+0.01;lo=max(0,lo-4);hi += 4
  let n=Int((0.5*(hi*hi-lo*lo)*(tb-ta)/9000).rounded())
  var random=NightRandom(seed:UInt32(truncatingIfNeeded:Int64(width*7919+height*104729+124)))
  var out:[NightStar]=[]
  let originX=ox,originY=oy
  func push(_ r:Double,_ t:Double,_ level:Int){out.append(NightStar(x:originX+r*cos(t),y:originY+r*sin(t),level:level));for _ in 0..<4 {_ = random.next()}}
  for _ in 0..<n {let r=sqrt(lo*lo+random.next()*(hi*hi-lo*lo)),t=ta+random.next()*(tb-ta),v=random.next();push(r,t,v<0.07 ? 0 : v<0.23 ? 1 : v<0.53 ? 2 : 3)}
  for _ in 0..<Int((Double(n)*2.6).rounded()) {let gs=sqrt(-2*log(random.next()+1e-9))*cos(6.283*random.next());push(arcRadius+gs*side/pow(Self.phi,4),ta+random.next()*(tb-ta),random.next()<0.12 ? 2 : 3)}
  stars=out;random=NightRandom(seed:1021);var ms:[NightMeteor]=[]
  for i in 0..<11 {
   let start=(Double(i)+0.15+random.next()*0.7)*54.5,duration=0.75+random.next()*0.5,beam=Int(floor(random.next()*10)),offset=1.05+random.next()*1.1,length=side*(0.16+random.next()*0.14)
   _ = random.next();ms.append(NightMeteor(start:start,duration:duration,beam:beam,offset:offset,length:length,brightness:0.65+random.next()*0.35))
  };meteors=ms
 }
 func point(_ t:Double)->CGPoint {CGPoint(x:ox+arcRadius*cos(a0+sweep*t),y:oy+arcRadius*sin(a0+sweep*t))}
 func rotate(_ x:Double,_ y:Double,_ angle:Double)->CGPoint {let dx=x-ox,dy=y-oy;return CGPoint(x:ox+dx*cos(angle)-dy*sin(angle),y:oy+dx*sin(angle)+dy*cos(angle))}
 func state(_ frame:NightFrame,rise:Double,set:Double,minute:Double)->NightState {
  let dusk=(set<rise ? set+1440:set)+30,dawn=rise-30,raw=Self.wrap(dawn-dusk),span=raw==0 ? 1440:raw,elapsed=Self.wrap(minute-dusk)
  var u=elapsed<=span ? elapsed/span : frame.t<0 ? 0.0:1.0;if frame.night<=0 {u=frame.t<0.5 ? 0:1}
  let half=max(0,min(180,span-120))/2,mid=Self.wrap(dusk+span/2),rel=Self.wrap(minute-(mid-half)),len=2*half
  let au=len>0 && rel<len ? Self.smooth(min(rel,len-rel)/min(45,len/2)):0
  return NightState(stars:max(0,min(1,frame.night*(1-0.62*frame.weight))),angle:sweep*(u-0.5),aurora:au,relative:Self.wrap(minute-mid),midnight:mid)
 }
 static func color(_ rgb:UInt32,_ alpha:Double)->CGColor {CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:[Double((rgb>>16)&255)/255,Double((rgb>>8)&255)/255,Double(rgb&255)/255,(max(0,min(1,alpha))*1000).rounded()/1000])!}
 static func context(_ width:Int,_ height:Int)->CGContext {let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!;c.translateBy(x:0,y:Double(height));c.scaleBy(x:1,y:-1);return c}
 static func ellipse(_ ctx:CGContext,_ p:CGPoint,_ r:Double,_ rgb:UInt32,_ alpha:Double){ctx.setFillColor(color(rgb,alpha));ctx.fillEllipse(in:CGRect(x:p.x-r,y:p.y-r,width:r*2,height:r*2))}
 static func dot(_ ctx:CGContext,_ p:CGPoint,_ r:Double,_ rgb:UInt32,_ alpha:Double){ellipse(ctx,p,r,rgb,alpha);if r>1.3 && alpha>0.4 {ellipse(ctx,p,r*2.6,rgb,alpha*0.16)}}
 func suppression(_ frame:NightFrame,_ p:CGPoint)->Double {var alpha=0.0;for g in frame.glows {let f=hypot(p.x-g.x,p.y-g.y)/g.radius;if f<1 {alpha += g.alpha*(f<=0.38 ? 1-0.55*f/0.38 : 0.45*(1-(f-0.38)/0.62))}};return 1-min(0.9,1.9*alpha)}
 func paintStatic(_ ctx:CGContext,frame:NightFrame,rise:Double,set:Double,minute:Double,dark:Bool,still:Bool,watch:Bool) {
  let ns=state(frame,rise:rise,set:set,minute:minute)
  // The watch's wrist-down sky keeps the aurora's once-a-minute shape: Always On redraws on the minute anyway.
  if ns.aurora>0.001 {paintAurora(ctx,ns:ns,minute:minute,dark:dark,still:still && !watch)}
  for st in stars {let i=Double(st.level),p=rotate(st.x,st.y,ns.angle);if p.x < -3 || p.y < -3 || p.x > width+3 || p.y > height+3 {continue}
   let a=0.92*pow(Self.phi,-0.75*i),threshold=[0.18,0.38,0.58,0.74][st.level],alpha=(dark ? a:min(1,a*1.05+0.08))*Self.smooth((ns.stars-threshold)/0.2)*suppression(frame,p)
   if alpha>=0.01 {Self.dot(ctx,p,1.75*pow(Self.phi,-0.5*i)*(dark ? 1:1.1),0xFFCC33,alpha)}
  }
  let centre=point(0.5),cv=Self.smooth((ns.stars-0.3)/0.35),levels=[0,1,0,0,1,0,0,1,0,1]
  for k in 0..<10 {let angle=Double(-90+36*k)*Double.pi/180,level=Double(levels[k]),p=rotate(centre.x+radius/Self.phi*cos(angle),centre.y+radius/Self.phi*sin(angle),ns.angle),a=0.92*pow(Self.phi,-0.75*level),alpha=min(1,(dark ? a:min(1,a*1.05+0.08))*1.25)*cv*suppression(frame,p),r=(1.75*pow(Self.phi,-0.5*level)*1.35+0.4)*0.8*(dark ? 1:1.1)
   if alpha>0.01 {Self.ellipse(ctx,p,r*4.2,0xFFCC33,alpha*0.14);Self.dot(ctx,p,r,0xFFCC33,alpha)}
  }
  if still || watch {paintMeteors(ctx,frame:frame,rise:rise,set:set,minute:minute,dark:dark,still:true)}
 }
 func paintAurora(_ ctx:CGContext,ns:NightState,minute:Double,dark:Bool,still:Bool) {
  let w=Int(ceil(width/4)),h=Int(ceil(height/4)),small=Self.context(w,h),phase=still ? 2.1:floor(minute)*0.9,peak=(dark ? 0.34:0.42*1.3)*ns.aurora
  for xi in 0..<w {let x=Double(xi)*4+2,dx=x-ox,yb=oy-sqrt(max(0,arcRadius*arcRadius-dx*dx))+side*0.04*sin(x/side*6+phase*0.8)
   let fold=0.5+0.5*sin(x/side*9+phase)*sin(x/side*3.3-phase*0.6),ray=Self.hash(Double(xi),floor(phase*3))*0.5+Self.hash(Double(xi+1),floor(phase*3))*0.5
   let intensity=peak*(0.3+0.7*fold*fold)*(0.55+0.45*sin(x/side*27+phase*2.3))*(0.45+0.75*ray)
   if intensity<0.004 {continue};let y0=yb/4+2,y1=(yb-side*0.42*(0.7+0.3*fold))/4
   let colors=[Self.color(0x6CF0A8,0),Self.color(0x6CF0A8,intensity),Self.color(0x6CF0A8,intensity*0.55),Self.color(0xA27CFF,intensity*0.3),Self.color(0xA27CFF,0)]
   let gradient=CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),colors:colors as CFArray,locations:[0,0.06,0.35,0.7,1])!
   small.saveGState();small.clip(to:CGRect(x:Double(xi),y:min(y0,y1),width:1.2,height:abs(y0-y1)));small.drawLinearGradient(gradient,start:CGPoint(x:0,y:y0),end:CGPoint(x:0,y:y1),options:[]);small.restoreGState()
  }
  #if os(watchOS)
  // watchOS has no CoreImage. The watch is always dark, so the aurora composites additively, and nine
  // offset draws at a ninth of the alpha sum to a box blur of the same strength as the blur below.
  if let image=small.makeImage() {ctx.saveGState();ctx.setBlendMode(.plusLighter);ctx.interpolationQuality = .high;ctx.setAlpha(1.0/9);ctx.translateBy(x:0,y:Double(h)*4);ctx.scaleBy(x:1,y:-1)
   for dx in [-2.0,0,2.0] {for dy in [-2.0,0,2.0] {ctx.draw(image,in:CGRect(x:dx,y:dy,width:Double(w)*4,height:Double(h)*4))}}
   ctx.restoreGState()}
  #else
  let source=CIImage(cgImage:small.makeImage()!),blurred=source.applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:0.9])
  if let image=imageContext.createCGImage(blurred,from:source.extent) {ctx.saveGState();ctx.setBlendMode(dark ? .plusLighter:.screen);ctx.interpolationQuality = .high;ctx.translateBy(x:0,y:Double(h)*4);ctx.scaleBy(x:1,y:-1);ctx.draw(image,in:CGRect(x:0,y:0,width:Double(w)*4,height:Double(h)*4));ctx.restoreGState()}
  #endif
 }
 static func line(_ ctx:CGContext,_ a:CGPoint,_ b:CGPoint,_ color:UInt32,_ alpha:Double,_ width:Double){
  ctx.saveGState();ctx.setLineWidth(width);ctx.setLineCap(.round);ctx.move(to:a);ctx.addLine(to:b);ctx.replacePathWithStrokedPath();ctx.clip()
  let gradient=CGGradient(colorsSpace:CGColorSpace(name:CGColorSpace.sRGB),colors:[Self.color(color,0),Self.color(color,alpha)] as CFArray,locations:[0,1])!;ctx.drawLinearGradient(gradient,start:a,end:b,options:[.drawsBeforeStartLocation,.drawsAfterEndLocation]);ctx.restoreGState()
 }
 func paintMeteors(_ ctx:CGContext,frame:NightFrame,rise:Double,set:Double,minute:Double,dark:Bool,still:Bool){
  let ns=state(frame,rise:rise,set:set,minute:minute);guard ns.relative<10 && ns.stars>0.2 else{return}
  let c=point(0.5),rad=rotate(c.x,c.y,ns.angle),sec=ns.relative*60,color:UInt32=dark ? 0xFCF3E4:0xFFFFFF,peak=dark ? 0.95:0.98
  for m in meteors {let dir=Double(-90+36*m.beam)*Double.pi/180,r=radius*6.5/13.5*(0.25+0.4*(m.offset-1.05)),ux=cos(dir),uy=sin(dir),x=rad.x+r*ux,y=rad.y+r*uy
   if still {if sec+59>=m.start {Self.line(ctx,CGPoint(x:x,y:y),CGPoint(x:x+ux*m.length,y:y+uy*m.length),color,peak*0.42*m.brightness,0.9)};continue}
   let t=(sec-m.start)/m.duration;if t<0 || t>1 {continue};let head=Self.smooth(t)*m.length,tail=min(head,m.length*0.42),fade=sin(Double.pi*min(1,t*1.1)),p=CGPoint(x:x+ux*head,y:y+uy*head)
   Self.line(ctx,CGPoint(x:p.x-ux*tail,y:p.y-uy*tail),p,color,peak*fade*m.brightness,1.4);Self.dot(ctx,p,1.1,color,peak*fade*m.brightness)
  }
 }

}
