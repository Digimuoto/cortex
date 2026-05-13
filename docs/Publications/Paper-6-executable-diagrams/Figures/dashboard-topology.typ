#import "dashboard-topology-module.typ": dashboard-topology

#set page(width: 170mm, height: 62mm, margin: 5mm)
#set text(font: "Libertinus Serif", size: 8pt)

#dashboard-topology()

#align(center)[
  #text(size: 7.3pt)[
    #emph[Figure 1:] Dashboard topology after admission. The `profile` endpoint is carried directly
    from `prepare_dashboard` to `assemble`.
  ]
]
