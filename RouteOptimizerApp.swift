import SwiftUI
import MapKit
import Combine
import UniformTypeIdentifiers
import UIKit
import CoreLocation

struct Stop: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var address: String?
    var latitude: Double?
    var longitude: Double?
    init(id: UUID = UUID(), name: String, address: String? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.id = id; self.name = name; self.address = address; self.latitude = latitude; self.longitude = longitude
    }
    var coordinate: CLLocationCoordinate2D? {
        if let lat = latitude, let lon = longitude { return CLLocationCoordinate2D(latitude: lat, longitude: lon) }
        return nil
    }
}
@MainActor
final class RouteVM: ObservableObject {
    @Published var stops: [Stop] = []
    @Published var optimized: [Stop] = []
    @Published var status: String = "Prêt"
    @Published var isBusy: Bool = false
    @Published var polylines: [MKPolyline] = []
    @Published var totalDistance: Double = 0
    @Published var totalTime: Double = 0
    @Published var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522),
                                               span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4))
    private let geocoder = CLGeocoder()
    func clearAll() { stops.removeAll(); optimized.removeAll(); polylines.removeAll(); totalDistance = 0; totalTime = 0; status = "Prêt" }
    func addStop(name: String, address: String? = nil, lat: Double? = nil, lon: Double? = nil) {
        stops.append(Stop(name: name.isEmpty ? (address ?? "Arrêt \\(stops.count+1)") : name, address: address, latitude: lat, longitude: lon))
    }
    func importCSV(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: .newlines).map{$0.trimmingCharacters(in: .whitespaces)}.filter{!$0.isEmpty}
        for line in lines {
            let p = line.split(separator: ",").map{String($0).trimmingCharacters(in: .whitespaces)}
            if p.count >= 3, let lat = Double(p[p.count-2]), let lon = Double(p.last!) { addStop(name: p.dropLast(2).joined(separator: ","), lat: lat, lon: lon) }
            else if p.count == 2, let lat = Double(p[0]), let lon = Double(p[1]) { addStop(name: "Arrêt \\(stops.count+1)", lat: lat, lon: lon) }
            else { let name = p.first ?? "Arrêt \\(stops.count+1)"; let addr = p.dropFirst().joined(separator: ","); addStop(name: name, address: addr.isEmpty ? name : addr) }
        }
    }
    func geocodeMissing() async {
        isBusy = true; defer { isBusy = false }; status = "Géocodage..."
        for i in stops.indices {
            if stops[i].coordinate != nil { continue }
            let query = stops[i].address ?? stops[i].name
            do {
                let placemarks = try await geocoder.geocodeAddressString(query)
                if let c = placemarks.first?.location?.coordinate { stops[i].latitude = c.latitude; stops[i].longitude = c.longitude }
            } catch { }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        status = "Géocodage terminé."
    }
    private func dist(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let R = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi/180, dLon = (b.longitude - a.longitude) * .pi/180
        let la1 = a.latitude * .pi/180, la2 = b.latitude * .pi/180
        let s = sin(dLat/2)*sin(dLat/2) + cos(la1)*cos(la2)*sin(dLon/2)*sin(dLon/2)
        return 2*atan2(sqrt(s), sqrt(1-s))*R
    }
    private func nearestNeighbor(_ pts: [Stop]) -> [Stop] {
        var u = pts; guard !u.isEmpty else { return [] }; var r:[Stop]=[]; var cur = u.removeFirst(); r.append(cur)
        while !u.isEmpty { var bi=0; var bd=Double.infinity; for i in 0..<u.count { let d = dist(cur.coordinate!, u[i].coordinate!); if d<bd {bd=d; bi=i} } ; cur = u.remove(at: bi); r.append(cur) }
        return r
    }
    private func twoOpt(_ route: [Stop]) -> [Stop] {
        guard route.count>3 else { return route }; var r=route; var improved=true
        while improved {
            improved=false
            for i in 0..<(r.count-2) {
                for j in (i+2)..<r.count {
                    if j==r.count-1 && i==0 { continue }
                    let a=r[i].coordinate!, b=r[i+1].coordinate!, c=r[j].coordinate!, d=r[(j+1)%r.count].coordinate!
                    let delta=(dist(a,c)+dist(b,d)) - (dist(a,b)+dist(c,d))
                    if delta < -1e-6 { let mid=Array(r[(i+1)...j].reversed()); r.replaceSubrange((i+1)...j, with: mid); improved=true }
                }
            }
        }
        return r
    }
    func optimize() async {
        await geocodeMissing()
        let pts = stops.compactMap{ $0.coordinate != nil ? $0 : nil }
        guard pts.count>=2 else { status="Ajoute au moins 2 arrêts."; return }
        status="Optimisation..."
        let best = twoOpt(nearestNeighbor(pts))
        optimized = best
        await computeDirections()
    }
    private func req(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> MKDirections.Request {
        let r = MKDirections.Request()
        r.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
        r.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
        r.transportType = .automobile
        return r
    }
    func computeDirections() async {
        isBusy=true; defer { isBusy=false }; status="Calcul d'itinéraires..."
        polylines.removeAll(); totalDistance=0; totalTime=0
        guard optimized.count>=2 else { status="Optimisé"; return }
        for i in 0..<(optimized.count-1) {
            if let a=optimized[i].coordinate, let b=optimized[i+1].coordinate {
                do { let resp = try await MKDirections(request: req(a,b)).calculate()
                    if let r = resp.routes.first { polylines.append(r.polyline); totalDistance+=r.distance; totalTime+=r.expectedTravelTime }
                } catch { }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        status="OK: \\(optimized.count) arrêts — \\(Int(totalDistance/1000)) km, \\(Int(totalTime/60)) min"
        if let first = optimized.first?.coordinate {
            region.center = first
            region.span = MKCoordinateSpan(latitudeDelta: 2.5, longitudeDelta: 2.5)
        }
    }
    func openInAppleMaps() {
        guard optimized.count>=2 else { return }
        let items = optimized.compactMap { s -> MKMapItem? in
            guard let c = s.coordinate else { return nil }
            let it = MKMapItem(placemark: MKPlacemark(coordinate: c)); it.name = s.name; return it
        }
        MKMapItem.openMaps(with: items, launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
    func openInGoogleMaps() {
        let route = optimized
        guard route.count >= 2 else { return }
        func ll(_ c: CLLocationCoordinate2D) -> String { "\\(c.latitude),\\(c.longitude)" }
        let coords = route.compactMap { $0.coordinate }
        guard coords.count == route.count else { return }
        let origin = ll(coords.first!)
        let destination = ll(coords.last!)
        let waypoints = coords.dropFirst().dropLast().map { ll($0) }.joined(separator: "|")

        var appURLString = "comgooglemaps://?directionsmode=driving&origin=\\(origin)&destination=\\(destination)"
        if !waypoints.isEmpty { appURLString += "&waypoints=\\(waypoints)" }

        var webURLString = "https://www.google.com/maps/dir/?api=1&travelmode=driving&origin=\\(origin)&destination=\\(destination)"
        if !waypoints.isEmpty {
            let wp = waypoints.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            webURLString += "&waypoints=\\(wp)"
        }

        if let appURL = URL(string: appURLString), UIApplication.shared.canOpenURL(appURL) {
            UIApplication.shared.open(appURL)
        } else if let webURL = URL(string: webURLString) {
            UIApplication.shared.open(webURL)
        }
    }
}
final class SearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query: String = ""
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()
    override init() {
        super.init()
        completer.delegate = self
        completer.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 46.2276, longitude: 2.2137),
                                              span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10))
    }
    func update(_ q: String) { query=q; completer.queryFragment=q }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) { results = completer.results }
}
struct ContentView: View {
    @StateObject var vm = RouteVM()
    @StateObject var sc = SearchCompleter()
    @State private var name = ""
    @State private var addr = ""
    @State private var showImporter = false
    var body: some View {
        NavigationView {
            VStack(spacing:0){
                MapContainer(polylines: vm.polylines, stops: vm.optimized, region: $vm.region)
                    .frame(height: 320)
                    .overlay(alignment: .topTrailing) {
                        VStack(spacing:8){
                            Button { Task{ await vm.optimize() } } label: {
                                Label("Optimiser", systemImage:"wand.and.stars")
                                    .padding(8).background(.ultraThinMaterial).cornerRadius(10)
                            }
                            Button { vm.openInAppleMaps() } label: {
                                Label("Ouvrir dans Plans", systemImage:"car")
                                    .padding(8).background(.ultraThinMaterial).cornerRadius(10)
                            }
                            Button { vm.openInGoogleMaps() } label: {
                                Label("Google Maps", systemImage:"map")
                                    .padding(8).background(.ultraThinMaterial).cornerRadius(10)
                            }
                        }.padding(8)
                    }
                HStack{ Text(vm.status).lineLimit(2); Spacer(); if vm.isBusy { ProgressView() } }
                    .padding().background(Color(UIColor.secondarySystemBackground))
                VStack(alignment:.leading, spacing:8){
                    HStack{
                        TextField("Nom (Client A)", text:$name).textFieldStyle(.roundedBorder)
                        TextField("Adresse ou lat,lon", text:$addr).textFieldStyle(.roundedBorder)
                    }
                    if !sc.results.isEmpty && !addr.isEmpty {
                        ScrollView(.horizontal, showsIndicators:false){
                            HStack{
                                ForEach(Array(sc.results.prefix(6).enumerated()), id: \.offset){ _, r in
                                    Button("\\(r.title), \\(r.subtitle)"){ addr="\\(r.title), \\(r.subtitle)"; sc.results=[] }
                                        .padding(.horizontal,10).padding(.vertical,6).background(Color(UIColor.tertiarySystemBackground)).cornerRadius(8)
                                }
                            }.padding(.horizontal,2)
                        }
                    }
                    HStack{
                        Button{
                            let t = addr.trimmingCharacters(in:.whitespacesAndNewlines)
                            if let latlon = parse(t) { vm.addStop(name:name, lat:latlon.0, lon:latlon.1) }
                            else { vm.addStop(name:name, address:t) }
                            name=""; addr=""
                        } label: { Label("Ajouter", systemImage:"plus.circle.fill") }
                        Spacer()
                        Button{ showImporter = true } label: { Label("Importer CSV", systemImage:"tray.and.arrow.down") }
                        Spacer()
                        Button(role:.destructive){ vm.clearAll() } label: { Label("Vider", systemImage:"trash") }
                    }
                }.padding(.horizontal).padding(.vertical,8)
                List{
                    Section("Arrêts (\\(vm.stops.count))"){ ForEach(vm.stops){ s in
                        VStack(alignment:.leading){
                            Text(s.name).font(.headline)
                            if let c=s.coordinate { Text(String(format:"%.5f, %.5f", c.latitude, c.longitude)).font(.caption) }
                            else { Text(s.address ?? "—").font(.caption) }
                        }
                    }.onDelete{ vm.stops.remove(atOffsets:$0) } }
                    Section("Ordre optimisé"){ ForEach(Array(vm.optimized.enumerated()), id:\\.element.id){ i,s in
                        HStack{ Text("\\(i+1).").frame(width:22, alignment:.trailing); Text(s.name) }
                    } }
                }.listStyle(.insetGrouped)
            }
            .navigationTitle("Optimiseur de tournées")
        }
        .fileImporter(isPresented:$showImporter, allowedContentTypes:[UTType.commaSeparatedText, .plainText]){ res in
            if case .success(let url) = res, let data = try? Data(contentsOf:url) { vm.importCSV(data) }
        }
        .onChange(of: addr){ newVal in if newVal.count>=3 { sc.update(newVal) } else { sc.results=[] } }
    }
    func parse(_ s:String)->(Double,Double)?{
        let p=s.split(separator:",").map{$0.trimmingCharacters(in:.whitespaces)}
        if p.count==2, let lat=Double(p[0]), let lon=Double(p[1]){ return (lat,lon) }
        return nil
    }
}
struct MapContainer: UIViewRepresentable {
    var polylines:[MKPolyline]; var stops:[Stop]; @Binding var region: MKCoordinateRegion
    func makeUIView(context: Context) -> MKMapView { let m=MKMapView(); m.delegate=context.coordinator; m.setRegion(region, animated:false); m.showsUserLocation=true; return m }
    func updateUIView(_ m: MKMapView, context: Context) {
        m.setRegion(region, animated:true); m.removeAnnotations(m.annotations); m.removeOverlays(m.overlays)
        for (i,s) in stops.enumerated(){ if let c=s.coordinate { let a=MKPointAnnotation(); a.coordinate=c; a.title="\\(i+1). \\(s.name)"; m.addAnnotation(a) } }
        for p in polylines { m.addOverlay(p) }
    }
    func makeCoordinator() -> C { C() }
    final class C: NSObject, MKMapViewDelegate {
        func mapView(_ mv: MKMapView, rendererFor o: MKOverlay) -> MKOverlayRenderer {
            if let p=o as? MKPolyline { let r=MKPolylineRenderer(polyline:p); r.lineWidth=5; r.strokeColor=.systemBlue; r.alpha=0.85; return r }
            return MKOverlayRenderer(overlay:o)
        }
    }
}
@main
struct RouteOptimizerApp: App { var body: some Scene { WindowGroup { ContentView() } } }
