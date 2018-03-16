fixmystreet.maps.tile_base = [ [ "", "a-" ], "https://{S}fix.bromley.gov.uk/tilma" ];

(function(){

if (!fixmystreet.maps) {
    return;
}

var defaults = {
    http_options: {
        url: "https://tilma.staging.mysociety.org/mapserver/bromley_wfs",
        params: {
            SERVICE: "WFS",
            VERSION: "1.1.0",
            REQUEST: "GetFeature",
            SRSNAME: "urn:ogc:def:crs:EPSG::3857"
        }
    },
    format_class: OpenLayers.Format.GML.v3.MultiCurveFix,
    asset_type: 'spot',
    max_resolution: 2.388657133579254,
    min_resolution: 0.5971642833948135,
    asset_id_field: 'CENTRAL_AS',
    attributes: {
        central_asset_id: 'CENTRAL_AS',
        site_code: 'SITE_CODE'
    },
    geometryName: 'msGeometry',
    srsName: "EPSG:3857",
    strategy_class: OpenLayers.Strategy.FixMyStreet
};

fixmystreet.assets.add($.extend(true, {}, defaults, {
    http_options: {
        params: {
            TYPENAME: "Streetlights"
        }
    },
    asset_category: ["Faulty street light"],
    asset_item: 'street light'
}));

fixmystreet.assets.add($.extend(true, {}, defaults, {
    http_options: {
        params: {
            TYPENAME: "Bins"
        }
    },
    asset_category: ["Overflowing litter bin"],
    asset_item: 'park bin',
    asset_item_message: 'For our parks, pick a <b class="asset-spot">bin</b> from the map &raquo;'
}));

fixmystreet.assets.add($.extend(true, {}, defaults, {
    http_options: {
        params: {
            TYPENAME: "Street_Trees"
        }
    },
    asset_category: ["Public Tree related issue"],
    asset_item: 'tree'
}));

var highways_stylemap = new OpenLayers.StyleMap({
    'default': new OpenLayers.Style({
        fill: false,
        stroke: false
    })
});

fixmystreet.assets.add($.extend(true, {}, defaults, {
    http_options: {
        params: {
            TYPENAME: "TFL_Red_Route"
        }
    },
    stylemap: highways_stylemap,
    always_visible: true,
    asset_category: ["Blocked drains", "Faulty street light", 'Faulty street sign', 'Floral displays', 'Obstructions (skips, A boards)', 'Overhanging vegetation from private land', 'Pavement defect', 'Public Tree related issue', "Road defect"],
    non_interactive: true
}));

var prow_stylemap = new OpenLayers.StyleMap({
    'default': new OpenLayers.Style({
        fill: false,
        fillOpacity: 0,
        strokeColor: "#660099",
        strokeOpacity: 0.5,
        strokeWidth: 6
    })
});

fixmystreet.assets.add($.extend(true, {}, defaults, {
    http_options: {
        params: {
            TYPENAME: "PROW"
        }
    },
    stylemap: prow_stylemap,
    always_visible: true,
    non_interactive: true
}));

})();
