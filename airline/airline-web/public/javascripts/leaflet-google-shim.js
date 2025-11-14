// Lightweight Leaflet-based shim to emulate key parts of the Google Maps JS API
// so existing code can continue to work while using OpenStreetMap tiles.
// Focused on: Map, Marker, Polyline, Circle, InfoWindow, ControlPosition,
// event helpers, geometry.spherical.interpolate, and visualization.HeatmapLayer.

(function() {
  if (window.google && window.google.maps && window.google.maps._shimLoaded) {
    return;
  }

  function ensureLeaflet() {
    if (!window.L) {
      console.error('Leaflet library is required before loading the shim.');
    }
  }

  ensureLeaflet();

  // Inject minimal CSS for a centered top control container
  try {
    var style = document.createElement('style');
    style.textContent = '.leaflet-top.leaflet-center { position: absolute; left: 50%; transform: translateX(-50%); top: 10px; z-index: 1000; }' +
      '.googleMapIcon, .googleMapButton { cursor: pointer; }';
    document.head.appendChild(style);
  } catch (e) {}

  var google = window.google || (window.google = {});
  var maps = google.maps || (google.maps = {});

  // Control positions mapping
  maps.ControlPosition = {
    RIGHT_BOTTOM: 'RIGHT_BOTTOM',
    LEFT_BOTTOM: 'LEFT_BOTTOM',
    TOP_CENTER: 'TOP_CENTER'
  };

  // LatLng
  maps.LatLng = function(lat, lng) {
    this.lat = typeof lat === 'number' ? lat : (lat && lat.lat) || 0;
    this.lng = typeof lng === 'number' ? lng : (lng && lng.lng) || 0;
  };
  maps.LatLng.prototype.lat = function() { return this.lat; };
  maps.LatLng.prototype.lng = function() { return this.lng; };

  // Point
  maps.Point = function(x, y) { this.x = x; this.y = y; };

  function toLeafletLatLng(ll) {
    if (!ll) return [0,0];
    if (ll instanceof maps.LatLng) { return [ll.lat, ll.lng]; }
    if (typeof ll.lat === 'number' && typeof ll.lng === 'number') { return [ll.lat, ll.lng]; }
    return [0,0];
  }

  function colorToCss(color) { return color; }

  // Map wrapper
  maps.Map = function(container, opts) {
    ensureLeaflet();
    var el = container && (container.nodeType ? container : document.getElementById(container)) || document.getElementById('map');
    var center = (opts && opts.center) || {lat: 0, lng: 0};
    var zoom = (opts && typeof opts.zoom === 'number') ? opts.zoom : 2;

    this._lmap = L.map(el, {
      zoomControl: (opts && (opts.zoomControl !== undefined)) ? opts.zoomControl : true,
      worldCopyJump: true,
      // Allow fractional zoom (quarter steps) so we can zoom-in by ~20%
      zoomSnap: 0.25,
      zoomDelta: 0.25
    });
    this.setCenter(center);
    this.setZoom(zoom);

    // Bounds restriction
    if (opts && opts.restriction && opts.restriction.latLngBounds) {
      var b = opts.restriction.latLngBounds;
      this._lmap.setMaxBounds([[b.south, b.west], [b.north, b.east]]);
    }

    // Create a dedicated labels pane below markers to avoid covering them
    try {
      this._labelsPane = this._lmap.createPane('labelsPane');
      this._labelsPane.style.zIndex = 450; // below markerPane (600)
    } catch (e) {}

    // Tile layers for light/dark styles
    // Use Carto Voyager base without labels, then overlay labels in a lower z-order pane
    this._tileLayerLight = L.tileLayer('https://{s}.basemaps.cartocdn.com/rastertiles/voyager_nolabels/{z}/{x}/{y}{r}.png', {
      maxZoom: (opts && opts.maxZoom) || 19,
      attribution: '&copy; OpenStreetMap contributors &copy; CARTO'
    }).addTo(this._lmap);
    this._tileLayerLabelsEn = L.tileLayer('https://{s}.basemaps.cartocdn.com/rastertiles/voyager_only_labels/{z}/{x}/{y}{r}.png', {
      maxZoom: (opts && opts.maxZoom) || 19,
      attribution: '&copy; CARTO',
      pane: 'labelsPane'
    }).addTo(this._lmap);
    this._tileLayerDark = L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
      maxZoom: (opts && opts.maxZoom) || 19,
    });
    // Default to light; map-style.js will toggle via setOptions
    this._currentTile = 'light';

    // Controls containers
    var mapContainer = this._lmap.getContainer();
    this.controls = {};
    // RIGHT_BOTTOM
    this.controls[maps.ControlPosition.RIGHT_BOTTOM] = createControlArray(this._lmap, 'bottomright');
    // LEFT_BOTTOM
    this.controls[maps.ControlPosition.LEFT_BOTTOM] = createControlArray(this._lmap, 'bottomleft');
    // TOP_CENTER (custom)
    var topCenter = document.createElement('div');
    topCenter.className = 'leaflet-top leaflet-center';
    mapContainer.appendChild(topCenter);
    this.controls[maps.ControlPosition.TOP_CENTER] = createControlArrayCustom(topCenter);

    this._events = {};
  };

  maps.Map.prototype.setCenter = function(center) {
    this._lmap.setView([center.lat, center.lng], this._lmap.getZoom());
  };
  maps.Map.prototype.setZoom = function(z) { this._lmap.setZoom(z); };
  maps.Map.prototype.getZoom = function() { return this._lmap.getZoom(); };
  maps.Map.prototype.getMapTypeId = function() { return 'roadmap'; };
  maps.Map.prototype.setOptions = function(opts) {
    if (!opts) return;
    if (opts.styles) {
      // Toggle tile layer between light/dark according to currentStyles global
      var useDark = (window.currentStyles === 'dark');
      if (useDark && this._currentTile !== 'dark') {
        this._lmap.removeLayer(this._tileLayerLight);
        if (this._tileLayerLabelsEn) { this._lmap.removeLayer(this._tileLayerLabelsEn); }
        this._tileLayerDark.addTo(this._lmap);
        this._currentTile = 'dark';
      } else if (!useDark && this._currentTile !== 'light') {
        this._lmap.removeLayer(this._tileLayerDark);
        this._tileLayerLight.addTo(this._lmap);
        if (this._tileLayerLabelsEn) { this._tileLayerLabelsEn.addTo(this._lmap); }
        this._currentTile = 'light';
      }
    }
  };

  function createControlArray(map, position) {
    var ctrl = new (L.Control.extend({
      options: { position: position },
      onAdd: function() { this._container = L.DomUtil.create('div'); return this._container; }
    }))();
    map.addControl(ctrl);
    var container = ctrl._container;
    var nodes = [];
    return {
      push: function(node) { nodes.push(node); container.appendChild(node); },
      insertAt: function(index, node) {
        if (index >= nodes.length) { this.push(node); return; }
        nodes.splice(index, 0, node);
        container.insertBefore(node, container.childNodes[index]);
      },
      clear: function() { nodes.forEach(function(n){ if (n && n.parentNode) n.parentNode.removeChild(n); }); nodes.length = 0; },
      getLength: function() { return nodes.length; }
    };
  }

  function createControlArrayCustom(container) {
    var nodes = [];
    return {
      push: function(node) { nodes.push(node); container.appendChild(node); },
      insertAt: function(index, node) {
        if (index >= nodes.length) { this.push(node); return; }
        nodes.splice(index, 0, node);
        container.insertBefore(node, container.childNodes[index]);
      },
      clear: function() { nodes.forEach(function(n){ if (n && n.parentNode) n.parentNode.removeChild(n); }); nodes.length = 0; },
      getLength: function() { return nodes.length; }
    };
  }

  // Event helpers similar to google.maps.event
  maps.event = {
    addListener: function(target, type, handler) {
      if (!target) return;
      if (target instanceof maps.Map) {
        if (type === 'zoom_changed') {
          target._lmap.on('zoomend', handler);
        } else if (type === 'idle') {
          target._lmap.on('moveend', handler);
        } else if (type === 'maptypeid_changed') {
          // no-op; trigger when setOptions called
        } else if (type === 'resize') {
          target._lmap.on('resize', handler);
        }
      } else if (target && target._on) {
        target._on(type, handler);
      } else if (target && target._l && target._l.on) {
        target._l.on(type, function(e) {
          handler(e);
        });
      }
      (target._handlers || (target._handlers = [])).push({ type: type, handler: handler });
      return { remove: function() { maps.event.clearListeners(target, type); } };
    },
    addListenerOnce: function(target, type, handler) {
      var once = function() { handler.apply(this, arguments); maps.event.clearListeners(target, type); };
      return maps.event.addListener(target, type, once);
    },
    clearListeners: function(target, type) {
      if (!target) return;
      if (target instanceof maps.Map) {
        if (type === 'zoom_changed') { target._lmap.off('zoomend'); }
        else if (type === 'idle') { target._lmap.off('moveend'); }
        else if (type === 'resize') { target._lmap.off('resize'); }
      } else if (target && target._l && target._l.off) {
        target._l.off(type);
      }
      if (target._handlers) target._handlers = target._handlers.filter(function(h){ return h.type !== type; });
    },
    clearInstanceListeners: function(target) {
      if (!target) return;
      if (target && target._l && target._l.off) { target._l.off(); }
      target._handlers = [];
    },
    trigger: function(target, type) {
      if (target instanceof maps.Map && type === 'resize') {
        target._lmap.invalidateSize(true);
      }
    }
  };

  // InfoWindow shim
  maps.InfoWindow = function(options) {
    this._options = options || {};
    this._popup = L.popup({ maxWidth: this._options.maxWidth || 300, autoPan: true });
    this.marker = null;
    this._events = {};
  };
  maps.InfoWindow.prototype.setContent = function(content) {
    this._popup.setContent(content);
  };
  maps.InfoWindow.prototype.setPosition = function(latLng) {
    var ll = latLng && (latLng.latLng || latLng);
    this._popup.setLatLng(toLeafletLatLng(ll));
  };
  maps.InfoWindow.prototype.open = function(map, marker) {
    this.marker = marker || null;
    if (marker && marker.getPosition) {
      var ll = marker.getPosition();
      this._popup.setLatLng(toLeafletLatLng(ll));
    }
    this._popup.openOn(map._lmap);
    // simulate 'closeclick' by listening to close event
    var self = this;
    this._popup.on('remove', function(){ if (self._events && self._events.closeclick) self._events.closeclick.call(self); });
  };
  maps.InfoWindow.prototype.close = function() {
    if (this._popup) this._popup.remove();
  };
  maps.InfoWindow.prototype.setMap = function(map) {
    if (!map) { this.close(); }
  };
  maps.InfoWindow.prototype.addListener = function(type, handler) {
    if (type === 'closeclick') { this._events.closeclick = handler; }
  };

  // Marker shim
  maps.Marker = function(options) {
    options = options || {};
    var pos = toLeafletLatLng(options.position);
    var iconOptions = {};
    if (typeof options.icon === 'string') {
      iconOptions = { iconUrl: options.icon };
    } else if (options.icon && options.icon.url) {
      var anchor = options.icon.anchor ? [options.icon.anchor.x || 0, options.icon.anchor.y || 0] : undefined;
      var size = options.icon.scaledSize || options.icon.size;
      var iconSize = size ? [size.width || size.w, size.height || size.h] : undefined;
      iconOptions = { iconUrl: options.icon.url, iconAnchor: anchor, iconSize: iconSize };
    }
    var icon = iconOptions.iconUrl ? L.icon(iconOptions) : undefined;
    // Only set icon if we actually have one; passing undefined overrides Leaflet's default and crashes
    var markerOptions = { interactive: options.clickable !== false, title: options.title };
    if (icon) { markerOptions.icon = icon; }
    this._marker = L.marker(pos, markerOptions);
    this._l = this._marker; // unify event target for clearListeners
    this._map = null;
    this._opacity = (typeof options.opacity === 'number') ? options.opacity : 1.0;
    this._marker.setOpacity(this._opacity);
    this._visible = true;
    this._zIndex = 0;
    this.icon = options.icon; // preserve google-style icon object for getIcon
    this._title = options.title || '';
    this._visibilityBindings = [];
    // allow arbitrary properties
    for (var k in options) { if (options.hasOwnProperty(k)) { this[k] = options[k]; } }

    if (options.map) { this.setMap(options.map); }
  };
  maps.Marker.prototype.setMap = function(map) {
    if (map) { this._marker.addTo(map._lmap); this._map = map; this._visible = true; }
    else { this._marker.remove(); this._map = null; this._visible = false; }
  };
  maps.Marker.prototype.setPosition = function(latLng) { this._marker.setLatLng(toLeafletLatLng(latLng)); };
  maps.Marker.prototype.addListener = function(type, handler) {
    var self = this;
    // Ensure Google-style 'this' binding to the shim Marker, not the Leaflet marker
    this._marker.on(type, function(e) { handler.call(self, e); });
  };
  maps.Marker.prototype.setOpacity = function(op) { this._opacity = op; this._marker.setOpacity(op); };
  maps.Marker.prototype.getOpacity = function() { return this._opacity; };
  maps.Marker.prototype.setVisible = function(v) {
    this._visible = !!v;
    if (this._visible) { if (this._map) this._marker.addTo(this._map._lmap); }
    else { this._marker.remove(); }
    // propagate to bindings
    for (var i = 0; i < this._visibilityBindings.length; i++) {
      var bound = this._visibilityBindings[i];
      if (bound && bound.setVisible) { bound.setVisible(this._visible); }
    }
  };
  maps.Marker.prototype.getPosition = function() { var ll = this._marker.getLatLng(); return new maps.LatLng(ll.lat, ll.lng); };
  maps.Marker.prototype.setZIndex = function(z) { this._zIndex = z || 0; this._marker.setZIndexOffset(this._zIndex); };
  maps.Marker.prototype.getZIndex = function() { return this._zIndex; };
  maps.Marker.prototype.setTitle = function(t) { this._title = t || ''; if (this._marker && this._marker._icon) { this._marker._icon.title = this._title; } };
  maps.Marker.prototype.getTitle = function() { return this._title; };
  maps.Marker.prototype.bindTo = function(prop, source) { if (prop === 'visible' && source) { source._visibilityBindings.push(this); this.setVisible(source._visible !== false); } };
  maps.Marker.prototype.setIcon = function(icon) {
    this.icon = icon;
    var anchor = icon && icon.anchor ? [icon.anchor.x || 0, icon.anchor.y || 0] : undefined;
    var size = icon && (icon.scaledSize || icon.size);
    var iconSize = size ? [size.width || size.w, size.height || size.h] : undefined;
    var url = (typeof icon === 'string') ? icon : (icon && icon.url);
    if (url) {
      var licon = L.icon({ iconUrl: url, iconAnchor: anchor, iconSize: iconSize });
      this._marker.setIcon(licon);
    }
  };
  maps.Marker.prototype.getIcon = function() { return this.icon; };

  // Polyline shim
  maps.Polyline = function(options) {
    options = options || {};
    var path = options.path || [];
    var latlngs = path.map(function(p){ return toLeafletLatLng(p); });
    var style = {
      color: colorToCss(options.strokeColor || '#000'),
      opacity: (typeof options.strokeOpacity === 'number') ? options.strokeOpacity : 1.0,
      weight: (typeof options.strokeWeight === 'number') ? options.strokeWeight : 2
    };
    this._layer = L.polyline(latlngs, style);
    this._map = null;
    this.strokeOpacity = style.opacity; // for code that reads this property
    this.path = options.path; // preserve original
    // preserve arbitrary properties
    for (var k in options) { if (options.hasOwnProperty(k)) { this[k] = options[k]; } }

    // event adapter
    var self = this;
    this._on = function(type, handler) {
      if (type === 'mouseover' || type === 'mouseout' || type === 'click') {
        self._layer.on(type, function(e) {
          handler({ latLng: new maps.LatLng(e.latlng.lat, e.latlng.lng), event: e });
        });
      }
    };
  };
  maps.Polyline.prototype.setMap = function(map) { if (map) { this._layer.addTo(map._lmap); this._map = map; } else { this._layer.remove(); this._map = null; } };
  maps.Polyline.prototype.getMap = function() { return this._map; };
  maps.Polyline.prototype.addListener = function(type, handler) { this._on(type, handler); };
  maps.Polyline.prototype.setOptions = function(opts) {
    opts = opts || {};
    var style = {};
    if (opts.strokeColor) style.color = colorToCss(opts.strokeColor);
    if (typeof opts.strokeOpacity === 'number') { style.opacity = opts.strokeOpacity; this.strokeOpacity = opts.strokeOpacity; }
    if (typeof opts.strokeWeight === 'number') style.weight = opts.strokeWeight;
    this._layer.setStyle(style);
  };
  maps.Polyline.prototype.getPath = function() {
    var arr = this.path || [];
    return {
      getAt: function(i) {
        var p = arr[i];
        if (p instanceof maps.LatLng) return p;
        return new maps.LatLng(p.lat, p.lng);
      }
    };
  };

  // Circle shim
  maps.Circle = function(options) {
    options = options || {};
    var center = toLeafletLatLng(options.center);
    this._layer = L.circle(center, {
      radius: options.radius || 1000,
      color: colorToCss(options.strokeColor || '#32CF47'),
      opacity: (typeof options.strokeOpacity === 'number') ? options.strokeOpacity : 0.2,
      weight: (typeof options.strokeWeight === 'number') ? options.strokeWeight : 2,
      fillColor: colorToCss(options.fillColor || '#32CF47'),
      fillOpacity: (typeof options.fillOpacity === 'number') ? options.fillOpacity : 0.3
    });
    this._map = null;
  };
  maps.Circle.prototype.setMap = function(map) { if (map) { this._layer.addTo(map._lmap); this._map = map; } else { this._layer.remove(); this._map = null; } };

  // geometry.spherical.interpolate
  maps.geometry = maps.geometry || {};
  maps.geometry.spherical = maps.geometry.spherical || {};
  maps.geometry.spherical.interpolate = function(from, to, fraction) {
    // Simple linear interpolation; acceptable approximation for short segments
    var lat = from.lat + (to.lat - from.lat) * fraction;
    var lng = from.lng + (to.lng - from.lng) * fraction;
    return new maps.LatLng(lat, lng);
  };

  // Heatmap shim using Leaflet.heat
  maps.visualization = maps.visualization || {};
  maps.visualization.HeatmapLayer = function(options) {
    options = options || {};
    this._options = options;
    this._layer = null;
  };
  maps.visualization.HeatmapLayer.prototype.setMap = function(map) {
    if (!map) {
      if (this._layer) { this._layer.remove(); this._layer = null; }
      return;
    }
    var pts = [];
    var data = this._options.data || [];
    for (var i = 0; i < data.length; i++) {
      var entry = data[i];
      var ll = entry.location instanceof maps.LatLng ? entry.location : new maps.LatLng(entry.location.lat, entry.location.lng);
      var weight = (typeof entry.weight === 'number') ? entry.weight : 1;
      pts.push([ll.lat, ll.lng, weight]);
    }
    var opts = {
      radius: (typeof this._options.radius === 'number') ? this._options.radius : 25,
      max: (typeof this._options.maxIntensity === 'number') ? this._options.maxIntensity : undefined
    };
    // Map array-based gradients to Leaflet.heat's object mapping
    var grad = this._options.gradient;
    if (grad && Array.isArray(grad) && grad.length > 1) {
      var stops = {};
      for (var i = 0; i < grad.length; i++) {
        var t = (grad.length === 1) ? 1 : i / (grad.length - 1);
        // Use CSS color strings directly
        stops[Number(t.toFixed(2))] = grad[i];
      }
      opts.gradient = stops;
    }
    this._layer = (this._layer || L.heatLayer(pts, opts));
    // Replace data if reusing layer
    if (this._layer) {
      this._layer.setLatLngs(pts);
      // Leaflet.heat does not expose setters for options; recreate layer if options changed significantly
      if (opts.gradient || (typeof this._options.radius === 'number')) {
        this._layer.remove();
        this._layer = L.heatLayer(pts, opts);
      }
      this._layer.addTo(map._lmap);
    }
  };

  maps._shimLoaded = true;
})();
