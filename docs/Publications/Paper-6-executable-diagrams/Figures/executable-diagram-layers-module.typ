#let diagram-ink = rgb("#172033")
#let diagram-muted = rgb("#596577")
#let diagram-rule = rgb("#b8c2d0")
#let diagram-fill = rgb("#f8fafc")
#let diagram-proof-fill = rgb("#eef5f0")

#let executable-diagram-layers() = {
  let diagram-node(body, fill: diagram-fill) = box(
    width: 25mm,
    height: 11.5mm,
    inset: 3pt,
    fill: fill,
    stroke: 0.45pt + diagram-rule,
    radius: 1.4pt,
    align(center + horizon, text(size: 7.3pt, fill: diagram-ink, body)),
  )

  let node(x, y, body, fill: diagram-fill) = place(
    top + left,
    dx: x,
    dy: y,
  )[#diagram-node(body, fill: fill)]

  let arrow(x, y) = place(
    top + left,
    dx: x,
    dy: y,
  )[#box(width: 6mm, align(center)[#text(size: 7.4pt, fill: diagram-muted)[->]])]

  let dotted(x, y, width, label) = place(
    top + left,
    dx: x,
    dy: y,
  )[
    #box(
      width: width,
      align(center)[#text(size: 6.6pt, fill: diagram-muted)[#label]],
    )
  ]

  let y-top = 0mm
  let y-arrow = 4.6mm
  let y-proof = 20mm

  let x-source = 0mm
  let x-linear = 31mm
  let x-relation = 62mm
  let x-circuit = 93mm
  let x-runtime = 124mm
  let x-arrow-a = 25mm
  let x-arrow-b = 56mm
  let x-arrow-c = 87mm
  let x-arrow-d = 118mm
  let x-proof = 31mm

  align(center)[
    #box(width: 150mm, height: 34mm)[
      #node(x-source, y-top)[Source diagram\ causal expression]
      #arrow(x-arrow-a, y-arrow)
      #node(x-linear, y-top)[Admitted frontier\ typed resources]
      #arrow(x-arrow-b, y-arrow)
      #node(x-relation, y-top)[Causal topology\ port-erased graph]
      #arrow(x-arrow-c, y-arrow)
      #node(x-circuit, y-top)[Circuit\ executable artifact]
      #arrow(x-arrow-d, y-arrow)
      #node(x-runtime, y-top)[Runtime trace\ schedule, replay]

      #node(x-proof, y-proof, fill: diagram-proof-fill)[Proof IR\ accepted objects]
      #dotted(5mm, 16mm, 51mm, [correspondence obligations])
      #dotted(55mm, 16mm, 55mm, [names post-elaboration objects])
    ]
  ]
}
