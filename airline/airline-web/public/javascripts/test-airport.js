var map
var testFlightPaths
var activeInput

$( document ).ready(function() {
    testFlightPaths = []
    activeInput = $("#fromAirport")
    loadTestAirlines()
})

function initMap() {
  map = new google.maps.Map(document.getElementById('map'), {
    center: {lat: 20, lng: 150.644},
       zoom : 2
  });
  // Ensure Leaflet map resizes to the new 80vh height
  try { if (map && map._lmap) { map._lmap.invalidateSize(true); } } catch (e) {}

  getTestAirports()
  refreshTestLinks()
}

function addTestMarkers(airports) {
    var positions = []
    for (i = 0; i < airports.length; i++) {
          var airportInfo = airports[i]
          // Coerce coordinates to numbers to avoid shim defaulting to [0,0]
          var lat = parseFloat(airportInfo.latitude)
          var lng = parseFloat(airportInfo.longitude)
          if (!isFinite(lat) || !isFinite(lng)) { continue }
          var position = {lat: lat, lng: lng};
          positions.push(position)
          var marker = new google.maps.Marker({
                position: position,
                map: map,
                title: airportInfo.name,
               	airportCode: airportInfo.iata,
               	airportId: airportInfo.id,
                icon: {
                  url: 'https://unpkg.com/leaflet%401.9.4/dist/images/marker-icon.png',
                  anchor: { x: 12, y: 41 },
                  size: { width: 25, height: 41 }
                }
              });
          // Raise z-index to ensure marker sits above labels overlay
          try { if (typeof marker.setZIndex === 'function') { marker.setZIndex(1000); } } catch (e) {}
          
          marker.addListener('click', function() {
              var airportId = this.airportId
              if (activeInput.is($("#fromAirport"))) {
                  $("#fromAirport").val(airportId)
                  activeInput = $("#toAirport")
              } else {
                  $("#toAirport").val(airportId)
                  activeInput = $("#fromAirport")
              }
          });
    }
    // Fit map view to include all markers
    try {
      if (positions.length > 0 && window.L && map && map._lmap) {
        var bounds = L.latLngBounds(positions.map(function(p){ return L.latLng(p.lat, p.lng) }))
        map._lmap.fitBounds(bounds, { padding: [40, 40] })
      }
    } catch (e) {}
}

function loadTestAirlines() {
    $.ajax({
        type: 'GET',
        url: "airlines",
        contentType: 'application/json; charset=utf-8',
        dataType: 'json',
        success: function(airlines) {
            $.each(airlines, function( key, airline ) {
                $("#airlineOption").append($("<option></option>").attr("value", airline.id).text(airline.name)); 
          	});
        },
        error: function(jqXHR, textStatus, errorThrown) {
                console.log(JSON.stringify(jqXHR));
                console.log("AJAX error: " + textStatus + ' : ' + errorThrown);
        }
    });
}

function loadConsumptions() {
	$("#consumptions").empty()
	$.ajax({
		type: 'GET',
		url: "link-consumptions",
	    contentType: 'application/json; charset=utf-8',
	    dataType: 'json',
	    success: function(consumptions) {
	    	$.each(consumptions, function( key, consumption ) {
	    		$("#consumptions").append($("<div></div>").text(consumption.airlineName + " - " + consumption.fromAirportCode + "=>" + consumption.toAirportCode + " : " + consumption.consumption)); 
	  		});
	    },
        error: function(jqXHR, textStatus, errorThrown) {
	            console.log(JSON.stringify(jqXHR));
	            console.log("AJAX error: " + textStatus + ' : ' + errorThrown);
	    }
	});
}

function insertTestLink() {
    if ($("#fromAirport").val() && $("#toAirport").val()) {
        var url = "test-links"
        var airportData = { 
            "fromAirportId" : parseInt($("#fromAirport").val()), 
            "toAirportId" : parseInt($("#toAirport").val()),
            "airlineId" : parseInt($("#airlineOption").val()),
            "capacity" : parseInt($("#capacity").val()), 
            "quality" : parseInt($("#quality").val()),
            "price" : parseFloat($("#price").val()) }
        $.ajax({
            type: 'PUT',
            url: url,
            data: JSON.stringify(airportData),
            contentType: 'application/json; charset=utf-8',
            dataType: 'json',
            success: function(savedLink) {
                drawTestFlightPath(savedLink)
            },
            error: function(jqXHR, textStatus, errorThrown) {
                    console.log(JSON.stringify(jqXHR));
                    console.log("AJAX error: " + textStatus + ' : ' + errorThrown);
            }
        });
    }
}

function removeAllTestLinks() {
    $.ajax({
        type: 'DELETE',
        url: "links",
        success: function() {
            refreshTestLinks()
        },
        error: function(jqXHR, textStatus, errorThrown) {
                console.log(JSON.stringify(jqXHR));
                console.log("AJAX error: " + textStatus + ' : ' + errorThrown);
        }
    });
    
    
}

function refreshTestLinks() {
    //remove all links from UI first
    $.each(testFlightPaths, function( key, value ) {
          value.setMap(null)
        });
    testFlightPaths = []
    
    $.ajax({
        type: 'GET',
        url: "links",
        contentType: 'application/json; charset=utf-8',
        dataType: 'json',
        success: function(links) {
            $.each(links, function( key, link ) {
                drawTestFlightPath(link)
          	});
        },
        error: function(jqXHR, textStatus, errorThrown) {
                console.log(JSON.stringify(jqXHR));
                console.log("AJAX error: " + textStatus + ' : ' + errorThrown);
        }
    });
}

function drawTestFlightPath(link) {
   var flightPath = new google.maps.Polyline({
     path: [{lat: link.fromLatitude, lng: link.fromLongitude}, {lat: link.toLatitude, lng: link.toLongitude}], 
     geodesic: true,
     strokeColor: '#F2B022',
     strokeOpacity: 1.0,
     strokeWeight: 2
                           });
   
   flightPath.setMap(map)
   testFlightPaths.push(flightPath)
}

function appendConsole(message) {
	$('#console').append( message + '<br/>')
}

function getTestAirports() {
    $.getJSON( "airports?count=200", function( data ) {
          addTestMarkers(data)
        });
}
	
	
	
	
	
	
