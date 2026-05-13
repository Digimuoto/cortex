#let diagram-ink = rgb("#172033")
#let diagram-muted = rgb("#596577")
#let diagram-rule = rgb("#b8c2d0")
#let diagram-fill = rgb("#f8fafc")
#let diagram-pure-fill = rgb("#eef5f0")
#let diagram-edge = rgb("#596577")
#let diagram-profile-edge = rgb("#304f8f")
#let diagram-label-bg = rgb("#ffffff")

#let dashboard-topology() = {
  let diagram-node(body, width: 19mm, fill: diagram-fill) = box(
    width: width,
    height: 8.8mm,
    inset: 2pt,
    fill: fill,
    stroke: 0.45pt + diagram-rule,
    radius: 1.4pt,
    align(center + horizon, text(size: 6.15pt, fill: diagram-ink, body)),
  )

  let node(x, y, body, width: 19mm, fill: diagram-fill) = place(
    top + left,
    dx: x,
    dy: y,
  )[#diagram-node(body, width: width, fill: fill)]

  let edge(x1, y1, x2, y2, angle: 0deg, ink: diagram-edge, width: 0.55pt) = {
    place(top + left, dx: x1, dy: y1)[
      #line(start: (0mm, 0mm), end: (x2 - x1, y2 - y1), stroke: width + ink)
    ]
    place(top + left, dx: x2, dy: y2)[
      #rotate(angle)[#polygon(
        (0pt, 0pt),
        (-3.3pt, -1.7pt),
        (-3.3pt, 1.7pt),
        fill: ink,
      )]
    ]
  }

  let label(x, y, body, fill: diagram-label-bg) = place(
    top + left,
    dx: x,
    dy: y,
  )[
    #box(
      inset: (x: 1.4pt, y: 0.4pt),
      fill: fill,
      align(center, text(size: 5.75pt, fill: diagram-muted, body)),
    )
  ]

  align(center)[
    #box(width: 148mm, height: 45mm)[
      #node(0mm, 18mm)[receive\ request]
      #node(23mm, 18mm)[fetch\ user]
      #node(46mm, 18mm, width: 23mm, fill: diagram-pure-fill)[prepare\ dashboard]
      #node(78mm, 3mm, width: 20mm)[fetch\ posts]
      #node(78mm, 33mm, width: 20mm)[fetch\ friends]
      #node(108mm, 18mm)[assemble]
      #node(131mm, 18mm, width: 17mm)[respond]

      #edge(19mm, 22.4mm, 23mm, 22.4mm)
      #edge(42mm, 22.4mm, 46mm, 22.4mm)
      #edge(69mm, 19.7mm, 78mm, 7.4mm, angle: -35deg)
      #edge(69mm, 25.1mm, 78mm, 37.4mm, angle: 35deg)
      #edge(69mm, 22.4mm, 108mm, 22.4mm, ink: diagram-profile-edge, width: 0.7pt)
      #edge(98mm, 7.4mm, 108mm, 20.1mm, angle: 35deg)
      #edge(98mm, 37.4mm, 108mm, 24.7mm, angle: -35deg)
      #edge(127mm, 22.4mm, 131mm, 22.4mm)

      #label(31mm, 14.4mm)[user]
      #label(70mm, 8.9mm)[posts_req]
      #label(68.4mm, 31.1mm)[friends_req]
      #label(85.6mm, 18.9mm, [profile], fill: rgb("#f6f8ff"))
      #label(100.5mm, 10.9mm)[posts]
      #label(99.2mm, 30.8mm)[friends]
    ]
  ]
}
