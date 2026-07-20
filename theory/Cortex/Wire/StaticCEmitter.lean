import Cortex.Wire.C11

/-!
## StaticC v1 structured lowering

The v1 scheduler and engine are represented entirely in the shared printable
C11 AST. This module contains no raw C declaration, function, or header text.
-/

namespace Cortex.Wire.StaticCEmitter

open Cortex.Wire.C11

def staticFunctions : List CFunction := [
  {
    name := "status_unblocks",
    result := .u8,
    params := [
      {
        name := "status",
        ty := .u8
      }
    ],
    body := some [
      .returnValue (
        .cast (
          .u8
        ) (
          .parenthesized (
            .binary .logicalOr (
              .binary .equal (
                .ident "status"
              ) (
                .ident "CORTEX_WIRE_STATUS_COMPLETED"
              )
            ) (
              .binary .equal (
                .ident "status"
              ) (
                .ident "CORTEX_WIRE_STATUS_SKIPPED"
              )
            )
          )
        )
      )
    ],
    visibility := .internal
  },
  {
    name := "node_ready",
    result := .u8,
    params := [
      {
        name := "node_id",
        ty := .u32
      }
    ],
    body := some [
      .local (
        {
          name := "cursor",
          ty := .u32,
          initial := none
        }
      ),
      .branch (
        .binary .notEqual (
          .index (
            .ident "node_status"
          ) (
            .ident "node_id"
          )
        ) (
          .ident "CORTEX_WIRE_STATUS_PENDING"
        )
      ) [
        .returnValue (
          .unsigned 0
        )
      ] [
      ],
      .forLoop (
        .assign (
          .ident "cursor"
        ) (
          .index (
            .ident "predecessor_offsets"
          ) (
            .ident "node_id"
          )
        )
      ) (
        .binary .less (
          .ident "cursor"
        ) (
          .index (
            .ident "predecessor_offsets"
          ) (
            .binary .add (
              .ident "node_id"
            ) (
              .unsigned 1
            )
          )
        )
      ) (
        .unary .preIncrement (
          .ident "cursor"
        )
      ) [
        .branch (
          .unary .logicalNot (
            .call (
              .ident "status_unblocks"
            ) [
              .index (
                .ident "node_status"
              ) (
                .index (
                  .ident "predecessor_nodes"
                ) (
                  .ident "cursor"
                )
              )
            ]
          )
        ) [
          .returnValue (
            .unsigned 0
          )
        ] [
        ]
      ],
      .returnValue (
        .unsigned 1
      )
    ],
    visibility := .internal
  },
  {
    name := "has_failed_predecessor",
    result := .u8,
    params := [
      {
        name := "node_id",
        ty := .u32
      }
    ],
    body := some [
      .local (
        {
          name := "cursor",
          ty := .u32,
          initial := none
        }
      ),
      .forLoop (
        .assign (
          .ident "cursor"
        ) (
          .index (
            .ident "predecessor_offsets"
          ) (
            .ident "node_id"
          )
        )
      ) (
        .binary .less (
          .ident "cursor"
        ) (
          .index (
            .ident "predecessor_offsets"
          ) (
            .binary .add (
              .ident "node_id"
            ) (
              .unsigned 1
            )
          )
        )
      ) (
        .unary .preIncrement (
          .ident "cursor"
        )
      ) [
        .branch (
          .binary .equal (
            .index (
              .ident "node_status"
            ) (
              .index (
                .ident "predecessor_nodes"
              ) (
                .ident "cursor"
              )
            )
          ) (
            .ident "CORTEX_WIRE_STATUS_FAILED"
          )
        ) [
          .returnValue (
            .unsigned 1
          )
        ] [
        ]
      ],
      .returnValue (
        .unsigned 0
      )
    ],
    visibility := .internal
  },
  {
    name := "propagate_failures",
    result := .void,
    params := [
    ],
    body := some [
      .local (
        {
          name := "order_index",
          ty := .u32,
          initial := none
        }
      ),
      .forLoop (
        .assign (
          .ident "order_index"
        ) (
          .unsigned 0
        )
      ) (
        .binary .less (
          .ident "order_index"
        ) (
          .ident "cortex_wire_node_count"
        )
      ) (
        .unary .preIncrement (
          .ident "order_index"
        )
      ) [
        .local (
          {
            name := "node_id",
            ty := .u32,
            initial := some (
              .index (
                .ident "topological_order"
              ) (
                .ident "order_index"
              )
            )
          }
        ),
        .branch (
          .binary .logicalAnd (
            .binary .equal (
              .index (
                .ident "node_status"
              ) (
                .ident "node_id"
              )
            ) (
              .ident "CORTEX_WIRE_STATUS_PENDING"
            )
          ) (
            .call (
              .ident "has_failed_predecessor"
            ) [
              .ident "node_id"
            ]
          )
        ) [
          .assign (
            .index (
              .ident "node_status"
            ) (
              .ident "node_id"
            )
          ) (
            .ident "CORTEX_WIRE_STATUS_FAILED"
          )
        ] [
        ]
      ]
    ],
    visibility := .internal
  },
  {
    name := "any_status",
    result := .u8,
    params := [
      {
        name := "expected",
        ty := .u8
      }
    ],
    body := some [
      .local (
        {
          name := "node_id",
          ty := .u32,
          initial := none
        }
      ),
      .forLoop (
        .assign (
          .ident "node_id"
        ) (
          .unsigned 0
        )
      ) (
        .binary .less (
          .ident "node_id"
        ) (
          .ident "cortex_wire_node_count"
        )
      ) (
        .unary .preIncrement (
          .ident "node_id"
        )
      ) [
        .branch (
          .binary .equal (
            .index (
              .ident "node_status"
            ) (
              .ident "node_id"
            )
          ) (
            .ident "expected"
          )
        ) [
          .returnValue (
            .unsigned 1
          )
        ] [
        ]
      ],
      .returnValue (
        .unsigned 0
      )
    ],
    visibility := .internal
  },
  {
    name := "all_settled",
    result := .u8,
    params := [
    ],
    body := some [
      .local (
        {
          name := "node_id",
          ty := .u32,
          initial := none
        }
      ),
      .forLoop (
        .assign (
          .ident "node_id"
        ) (
          .unsigned 0
        )
      ) (
        .binary .less (
          .ident "node_id"
        ) (
          .ident "cortex_wire_node_count"
        )
      ) (
        .unary .preIncrement (
          .ident "node_id"
        )
      ) [
        .local (
          {
            name := "status",
            ty := .u8,
            initial := some (
              .index (
                .ident "node_status"
              ) (
                .ident "node_id"
              )
            )
          }
        ),
        .branch (
          .binary .logicalAnd (
            .binary .logicalAnd (
              .binary .notEqual (
                .ident "status"
              ) (
                .ident "CORTEX_WIRE_STATUS_COMPLETED"
              )
            ) (
              .binary .notEqual (
                .ident "status"
              ) (
                .ident "CORTEX_WIRE_STATUS_FAILED"
              )
            )
          ) (
            .binary .notEqual (
              .ident "status"
            ) (
              .ident "CORTEX_WIRE_STATUS_SKIPPED"
            )
          )
        ) [
          .returnValue (
            .unsigned 0
          )
        ] [
        ]
      ],
      .returnValue (
        .unsigned 1
      )
    ],
    visibility := .internal
  },
  {
    name := "latch_terminal_failure",
    result := .void,
    params := [
    ],
    body := some [
      .local (
        {
          name := "node_id",
          ty := .u32,
          initial := none
        }
      ),
      .branch (
        .binary .notEqual (
          .ident "terminal_failed"
        ) (
          .unsigned 0
        )
      ) [
        .returnVoid
      ] [
      ],
      .assign (
        .ident "terminal_failed"
      ) (
        .unsigned 1
      ),
      .forLoop (
        .assign (
          .ident "node_id"
        ) (
          .unsigned 0
        )
      ) (
        .binary .less (
          .ident "node_id"
        ) (
          .ident "cortex_wire_node_count"
        )
      ) (
        .unary .preIncrement (
          .ident "node_id"
        )
      ) [
        .branch (
          .binary .equal (
            .index (
              .ident "node_status"
            ) (
              .ident "node_id"
            )
          ) (
            .ident "CORTEX_WIRE_STATUS_RUNNING"
          )
        ) [
          .branch (
            .binary .notEqual (
              .field (
                .ident "effect_api"
              ) "effect_cancel"
            ) (
              .signed 0
            )
          ) [
            .evaluate (
              .call (
                .field (
                  .ident "effect_api"
                ) "effect_cancel"
              ) [
                .ident "node_id",
                .field (
                  .ident "effect_api"
                ) "context"
              ]
            )
          ] [
          ],
          .assign (
            .index (
              .ident "node_status"
            ) (
              .ident "node_id"
            )
          ) (
            .ident "CORTEX_WIRE_STATUS_FAILED"
          )
        ] [
        ]
      ]
    ],
    visibility := .internal
  },
  {
    name := "cortex_wire_program_v1_init",
    result := .int,
    params := [
      {
        name := "api",
        ty := .pointer (
          .named "cortex_wire_program_v1_effect_api"
        ) true
      }
    ],
    body := some [
      .local (
        {
          name := "node_id",
          ty := .u32,
          initial := none
        }
      ),
      .branch (
        .binary .logicalOr (
          .binary .logicalOr (
            .binary .logicalOr (
              .binary .equal (
                .ident "api"
              ) (
                .signed 0
              )
            ) (
              .binary .equal (
                .pointerField (
                  .ident "api"
                ) "effect_begin"
              ) (
                .signed 0
              )
            )
          ) (
            .binary .notEqual (
              .ident "initialized"
            ) (
              .unsigned 0
            )
          )
        ) (
          .binary .notEqual (
            .ident "driving"
          ) (
            .unsigned 0
          )
        )
      ) [
        .returnValue (
          .unary .negate (
            .signed 1
          )
        )
      ] [
      ],
      .assign (
        .ident "effect_api"
      ) (
        .unary .dereference (
          .ident "api"
        )
      ),
      .forLoop (
        .assign (
          .ident "node_id"
        ) (
          .unsigned 0
        )
      ) (
        .binary .less (
          .ident "node_id"
        ) (
          .ident "cortex_wire_node_count"
        )
      ) (
        .unary .preIncrement (
          .ident "node_id"
        )
      ) [
        .assign (
          .index (
            .ident "node_status"
          ) (
            .ident "node_id"
          )
        ) (
          .ident "CORTEX_WIRE_STATUS_PENDING"
        ),
        .assign (
          .index (
            .ident "output_handle"
          ) (
            .ident "node_id"
          )
        ) (
          .unsigned 0
        ),
        .assign (
          .index (
            .ident "frontier_snapshot"
          ) (
            .ident "node_id"
          )
        ) (
          .unsigned 0
        )
      ],
      .assign (
        .ident "terminal_failed"
      ) (
        .unsigned 0
      ),
      .assign (
        .ident "initialized"
      ) (
        .unsigned 1
      ),
      .returnValue (
        .signed 0
      )
    ],
    visibility := .exported
  },
  {
    name := "cortex_wire_program_v1_drive",
    result := .named "cortex_wire_program_v1_drive_result",
    params := [
    ],
    body := some [
      .local (
        {
          name := "node_id",
          ty := .u32,
          initial := none
        }
      ),
      .branch (
        .binary .logicalOr (
          .binary .equal (
            .ident "initialized"
          ) (
            .unsigned 0
          )
        ) (
          .binary .notEqual (
            .ident "driving"
          ) (
            .unsigned 0
          )
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_DRIVE_ABI_ERROR"
        )
      ] [
      ],
      .branch (
        .binary .notEqual (
          .ident "terminal_failed"
        ) (
          .unsigned 0
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_DRIVE_FAILED"
        )
      ] [
      ],
      .assign (
        .ident "driving"
      ) (
        .unsigned 1
      ),
      .forever [
        .local (
          {
            name := "frontier_count",
            ty := .u32,
            initial := some (
              .unsigned 0
            )
          }
        ),
        .evaluate (
          .call (
            .ident "propagate_failures"
          ) [
          ]
        ),
        .branch (
          .call (
            .ident "any_status"
          ) [
            .ident "CORTEX_WIRE_STATUS_FAILED"
          ]
        ) [
          .evaluate (
            .call (
              .ident "latch_terminal_failure"
            ) [
            ]
          ),
          .assign (
            .ident "driving"
          ) (
            .unsigned 0
          ),
          .returnValue (
            .ident "CORTEX_WIRE_DRIVE_FAILED"
          )
        ] [
        ],
        .forLoop (
          .assign (
            .ident "node_id"
          ) (
            .unsigned 0
          )
        ) (
          .binary .less (
            .ident "node_id"
          ) (
            .ident "cortex_wire_node_count"
          )
        ) (
          .unary .preIncrement (
            .ident "node_id"
          )
        ) [
          .assign (
            .index (
              .ident "frontier_snapshot"
            ) (
              .ident "node_id"
            )
          ) (
            .call (
              .ident "node_ready"
            ) [
              .ident "node_id"
            ]
          ),
          .branch (
            .binary .notEqual (
              .index (
                .ident "frontier_snapshot"
              ) (
                .ident "node_id"
              )
            ) (
              .unsigned 0
            )
          ) [
            .evaluate (
              .unary .preIncrement (
                .ident "frontier_count"
              )
            )
          ] [
          ]
        ],
        .branch (
          .binary .equal (
            .ident "frontier_count"
          ) (
            .unsigned 0
          )
        ) [
          .assign (
            .ident "driving"
          ) (
            .unsigned 0
          ),
          .branch (
            .call (
              .ident "any_status"
            ) [
              .ident "CORTEX_WIRE_STATUS_RUNNING"
            ]
          ) [
            .returnValue (
              .ident "CORTEX_WIRE_DRIVE_AWAITING_COMPLETIONS"
            )
          ] [
          ],
          .branch (
            .call (
              .ident "all_settled"
            ) [
            ]
          ) [
            .returnValue (
              .ident "CORTEX_WIRE_DRIVE_COMPLETED"
            )
          ] [
          ],
          .returnValue (
            .ident "CORTEX_WIRE_DRIVE_STUCK"
          )
        ] [
        ],
        .forLoop (
          .assign (
            .ident "node_id"
          ) (
            .unsigned 0
          )
        ) (
          .binary .less (
            .ident "node_id"
          ) (
            .ident "cortex_wire_node_count"
          )
        ) (
          .unary .preIncrement (
            .ident "node_id"
          )
        ) [
          .local (
            {
              name := "effect",
              ty := .named "cortex_wire_program_v1_effect_result",
              initial := none
            }
          ),
          .branch (
            .binary .equal (
              .index (
                .ident "frontier_snapshot"
              ) (
                .ident "node_id"
              )
            ) (
              .unsigned 0
            )
          ) [
            .continue
          ] [
          ],
          .assign (
            .index (
              .ident "node_status"
            ) (
              .ident "node_id"
            )
          ) (
            .ident "CORTEX_WIRE_STATUS_RUNNING"
          ),
          .assign (
            .ident "effect"
          ) (
            .call (
              .field (
                .ident "effect_api"
              ) "effect_begin"
            ) [
              .ident "node_id",
              .field (
                .ident "effect_api"
              ) "context"
            ]
          ),
          .switch (
            .field (
              .ident "effect"
            ) "kind"
          ) [
            {
              value := .ident "CORTEX_WIRE_EFFECT_ACCEPTED_ASYNC",
              body := [
                .break
              ]
            },
            {
              value := .ident "CORTEX_WIRE_EFFECT_SUCCESS",
              body := [
                .assign (
                  .index (
                    .ident "node_status"
                  ) (
                    .ident "node_id"
                  )
                ) (
                  .ident "CORTEX_WIRE_STATUS_COMPLETED"
                ),
                .assign (
                  .index (
                    .ident "output_handle"
                  ) (
                    .ident "node_id"
                  )
                ) (
                  .field (
                    .ident "effect"
                  ) "payload_handle"
                ),
                .break
              ]
            },
            {
              value := .ident "CORTEX_WIRE_EFFECT_SKIPPED",
              body := [
                .assign (
                  .index (
                    .ident "node_status"
                  ) (
                    .ident "node_id"
                  )
                ) (
                  .ident "CORTEX_WIRE_STATUS_SKIPPED"
                ),
                .break
              ]
            },
            {
              value := .ident "CORTEX_WIRE_EFFECT_FAILURE",
              body := [
                .assign (
                  .index (
                    .ident "node_status"
                  ) (
                    .ident "node_id"
                  )
                ) (
                  .ident "CORTEX_WIRE_STATUS_FAILED"
                ),
                .break
              ]
            }
          ] [
            .assign (
              .index (
                .ident "node_status"
              ) (
                .ident "node_id"
              )
            ) (
              .ident "CORTEX_WIRE_STATUS_FAILED"
            ),
            .break
          ],
          .branch (
            .binary .equal (
              .index (
                .ident "node_status"
              ) (
                .ident "node_id"
              )
            ) (
              .ident "CORTEX_WIRE_STATUS_FAILED"
            )
          ) [
            .break
          ] [
          ]
        ]
      ]
    ],
    visibility := .exported
  },
  {
    name := "cortex_wire_program_v1_complete",
    result := .named "cortex_wire_program_v1_completion_result",
    params := [
      {
        name := "node_id",
        ty := .u32
      },
      {
        name := "outcome",
        ty := .named "cortex_wire_program_v1_effect_kind"
      },
      {
        name := "payload",
        ty := .u64
      }
    ],
    body := some [
      .branch (
        .binary .logicalOr (
          .binary .logicalOr (
            .binary .equal (
              .ident "initialized"
            ) (
              .unsigned 0
            )
          ) (
            .binary .notEqual (
              .ident "driving"
            ) (
              .unsigned 0
            )
          )
        ) (
          .binary .greaterEqual (
            .ident "node_id"
          ) (
            .ident "cortex_wire_node_count"
          )
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_COMPLETION_INVALID"
        )
      ] [
      ],
      .branch (
        .binary .notEqual (
          .ident "terminal_failed"
        ) (
          .unsigned 0
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_COMPLETION_STALE"
        )
      ] [
      ],
      .branch (
        .binary .notEqual (
          .index (
            .ident "node_status"
          ) (
            .ident "node_id"
          )
        ) (
          .ident "CORTEX_WIRE_STATUS_RUNNING"
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_COMPLETION_STALE"
        )
      ] [
      ],
      .switch (
        .ident "outcome"
      ) [
        {
          value := .ident "CORTEX_WIRE_EFFECT_SUCCESS",
          body := [
            .assign (
              .index (
                .ident "node_status"
              ) (
                .ident "node_id"
              )
            ) (
              .ident "CORTEX_WIRE_STATUS_COMPLETED"
            ),
            .assign (
              .index (
                .ident "output_handle"
              ) (
                .ident "node_id"
              )
            ) (
              .ident "payload"
            ),
            .break
          ]
        },
        {
          value := .ident "CORTEX_WIRE_EFFECT_SKIPPED",
          body := [
            .assign (
              .index (
                .ident "node_status"
              ) (
                .ident "node_id"
              )
            ) (
              .ident "CORTEX_WIRE_STATUS_SKIPPED"
            ),
            .break
          ]
        },
        {
          value := .ident "CORTEX_WIRE_EFFECT_FAILURE",
          body := [
            .assign (
              .index (
                .ident "node_status"
              ) (
                .ident "node_id"
              )
            ) (
              .ident "CORTEX_WIRE_STATUS_FAILED"
            ),
            .break
          ]
        }
      ] [
        .returnValue (
          .ident "CORTEX_WIRE_COMPLETION_INVALID"
        )
      ],
      .returnValue (
        .ident "CORTEX_WIRE_COMPLETION_APPLIED"
      )
    ],
    visibility := .exported
  },
  {
    name := "cortex_wire_program_v1_terminal",
    result := .named "cortex_wire_program_v1_terminal_state",
    params := [
    ],
    body := some [
      .branch (
        .binary .equal (
          .ident "initialized"
        ) (
          .unsigned 0
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_TERMINAL_ACTIVE"
        )
      ] [
      ],
      .branch (
        .binary .logicalOr (
          .binary .notEqual (
            .ident "terminal_failed"
          ) (
            .unsigned 0
          )
        ) (
          .call (
            .ident "any_status"
          ) [
            .ident "CORTEX_WIRE_STATUS_FAILED"
          ]
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_TERMINAL_FAILED"
        )
      ] [
      ],
      .branch (
        .call (
          .ident "all_settled"
        ) [
        ]
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_TERMINAL_COMPLETED"
        )
      ] [
      ],
      .returnValue (
        .ident "CORTEX_WIRE_TERMINAL_ACTIVE"
      )
    ],
    visibility := .exported
  },
  {
    name := "cortex_wire_program_v1_node_count",
    result := .u32,
    params := [
    ],
    body := some [
      .returnValue (
        .ident "cortex_wire_node_count"
      )
    ],
    visibility := .exported
  },
  {
    name := "cortex_wire_program_v1_node_status",
    result := .named "cortex_wire_program_v1_status",
    params := [
      {
        name := "node_id",
        ty := .u32
      }
    ],
    body := some [
      .branch (
        .binary .greaterEqual (
          .ident "node_id"
        ) (
          .ident "cortex_wire_node_count"
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_STATUS_INVALID"
        )
      ] [
      ],
      .returnValue (
        .cast (
          .named "cortex_wire_program_v1_status"
        ) (
          .index (
            .ident "node_status"
          ) (
            .ident "node_id"
          )
        )
      )
    ],
    visibility := .exported
  },
  {
    name := "cortex_wire_program_v1_output_handle",
    result := .u64,
    params := [
      {
        name := "node_id",
        ty := .u32
      }
    ],
    body := some [
      .branch (
        .binary .greaterEqual (
          .ident "node_id"
        ) (
          .ident "cortex_wire_node_count"
        )
      ) [
        .returnValue (
          .unsigned 0
        )
      ] [
      ],
      .returnValue (
        .index (
          .ident "output_handle"
        ) (
          .ident "node_id"
        )
      )
    ],
    visibility := .exported
  },
  {
    name := "engine_identity_matches",
    result := .u8,
    params := [
      {
        name := "candidate",
        ty := .pointer (
          .char
        ) true
      }
    ],
    body := some [
      .local (
        {
          name := "cursor",
          ty := .u32,
          initial := some (
            .unsigned 0
          )
        }
      ),
      .branch (
        .binary .equal (
          .ident "candidate"
        ) (
          .signed 0
        )
      ) [
        .returnValue (
          .unsigned 0
        )
      ] [
      ],
      .forever [
        .branch (
          .binary .notEqual (
            .index (
              .ident "candidate"
            ) (
              .ident "cursor"
            )
          ) (
            .index (
              .ident "engine_program_identity"
            ) (
              .ident "cursor"
            )
          )
        ) [
          .returnValue (
            .unsigned 0
          )
        ] [
        ],
        .branch (
          .binary .equal (
            .index (
              .ident "engine_program_identity"
            ) (
              .ident "cursor"
            )
          ) (
            .character '\x00'
          )
        ) [
          .returnValue (
            .unsigned 1
          )
        ] [
        ],
        .evaluate (
          .unary .preIncrement (
            .ident "cursor"
          )
        )
      ]
    ],
    visibility := .internal
  },
  {
    name := "engine_status_valid",
    result := .u8,
    params := [
      {
        name := "status",
        ty := .u8
      }
    ],
    body := some [
      .returnValue (
        .cast (
          .u8
        ) (
          .parenthesized (
            .binary .logicalOr (
              .binary .logicalOr (
                .binary .logicalOr (
                  .binary .equal (
                    .ident "status"
                  ) (
                    .ident "CORTEX_WIRE_STATUS_PENDING"
                  )
                ) (
                  .binary .equal (
                    .ident "status"
                  ) (
                    .ident "CORTEX_WIRE_STATUS_COMPLETED"
                  )
                )
              ) (
                .binary .equal (
                  .ident "status"
                ) (
                  .ident "CORTEX_WIRE_STATUS_FAILED"
                )
              )
            ) (
              .binary .equal (
                .ident "status"
              ) (
                .ident "CORTEX_WIRE_STATUS_SKIPPED"
              )
            )
          )
        )
      )
    ],
    visibility := .internal
  },
  {
    name := "engine_validate_state",
    result := .named "cortex_wire_engine_v1_state_result",
    params := [
      {
        name := "program_identity",
        ty := .pointer (
          .char
        ) true
      },
      {
        name := "header",
        ty := .pointer (
          .named "cortex_wire_engine_v1_state_header"
        ) true
      },
      {
        name := "statuses",
        ty := .pointer (
          .u8
        ) true
      },
      {
        name := "handles",
        ty := .pointer (
          .u64
        ) true
      },
      {
        name := "capacity",
        ty := .u32
      }
    ],
    body := some [
      .local (
        {
          name := "node_id",
          ty := .u32,
          initial := none
        }
      ),
      .local (
        {
          name := "any_failed",
          ty := .u8,
          initial := some (
            .unsigned 0
          )
        }
      ),
      .local (
        {
          name := "settled",
          ty := .u8,
          initial := some (
            .unsigned 1
          )
        }
      ),
      .branch (
        .unary .logicalNot (
          .call (
            .ident "engine_identity_matches"
          ) [
            .ident "program_identity"
          ]
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_ENGINE_STATE_IDENTITY_MISMATCH"
        )
      ] [
      ],
      .branch (
        .binary .logicalOr (
          .binary .logicalOr (
            .binary .logicalOr (
              .binary .logicalOr (
                .binary .logicalOr (
                  .binary .logicalOr (
                    .binary .logicalOr (
                      .binary .equal (
                        .ident "header"
                      ) (
                        .signed 0
                      )
                    ) (
                      .binary .equal (
                        .ident "statuses"
                      ) (
                        .signed 0
                      )
                    )
                  ) (
                    .binary .equal (
                      .ident "handles"
                    ) (
                      .signed 0
                    )
                  )
                ) (
                  .binary .notEqual (
                    .pointerField (
                      .ident "header"
                    ) "schema_version"
                  ) (
                    .ident "CORTEX_WIRE_ENGINE_STATE_SCHEMA_VERSION"
                  )
                )
              ) (
                .binary .notEqual (
                  .pointerField (
                    .ident "header"
                  ) "node_count"
                ) (
                  .ident "cortex_wire_node_count"
                )
              )
            ) (
              .binary .equal (
                .pointerField (
                  .ident "header"
                ) "checkpoint_sequence"
              ) (
                .unsigned 0
              )
            )
          ) (
            .binary .less (
              .ident "capacity"
            ) (
              .ident "cortex_wire_node_count"
            )
          )
        ) (
          .binary .greater (
            .pointerField (
              .ident "header"
            ) "terminal"
          ) (
            .ident "CORTEX_WIRE_ENGINE_TERMINAL_CANCELLED"
          )
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_ENGINE_STATE_INVALID"
        )
      ] [
      ],
      .forLoop (
        .assign (
          .ident "node_id"
        ) (
          .unsigned 0
        )
      ) (
        .binary .less (
          .ident "node_id"
        ) (
          .ident "cortex_wire_node_count"
        )
      ) (
        .unary .preIncrement (
          .ident "node_id"
        )
      ) [
        .local (
          {
            name := "cursor",
            ty := .u32,
            initial := none
          }
        ),
        .local (
          {
            name := "status",
            ty := .u8,
            initial := some (
              .index (
                .ident "statuses"
              ) (
                .ident "node_id"
              )
            )
          }
        ),
        .branch (
          .unary .logicalNot (
            .call (
              .ident "engine_status_valid"
            ) [
              .ident "status"
            ]
          )
        ) [
          .returnValue (
            .ident "CORTEX_WIRE_ENGINE_STATE_INVALID"
          )
        ] [
        ],
        .branch (
          .binary .logicalOr (
            .parenthesized (
              .binary .logicalAnd (
                .binary .equal (
                  .ident "status"
                ) (
                  .ident "CORTEX_WIRE_STATUS_COMPLETED"
                )
              ) (
                .binary .equal (
                  .index (
                    .ident "handles"
                  ) (
                    .ident "node_id"
                  )
                ) (
                  .unsigned 0
                )
              )
            )
          ) (
            .parenthesized (
              .binary .logicalAnd (
                .binary .notEqual (
                  .ident "status"
                ) (
                  .ident "CORTEX_WIRE_STATUS_COMPLETED"
                )
              ) (
                .binary .notEqual (
                  .index (
                    .ident "handles"
                  ) (
                    .ident "node_id"
                  )
                ) (
                  .unsigned 0
                )
              )
            )
          )
        ) [
          .returnValue (
            .ident "CORTEX_WIRE_ENGINE_STATE_INVALID"
          )
        ] [
        ],
        .branch (
          .binary .equal (
            .ident "status"
          ) (
            .ident "CORTEX_WIRE_STATUS_FAILED"
          )
        ) [
          .assign (
            .ident "any_failed"
          ) (
            .unsigned 1
          )
        ] [
        ],
        .branch (
          .binary .equal (
            .ident "status"
          ) (
            .ident "CORTEX_WIRE_STATUS_PENDING"
          )
        ) [
          .assign (
            .ident "settled"
          ) (
            .unsigned 0
          )
        ] [
        ],
        .branch (
          .binary .logicalOr (
            .binary .equal (
              .ident "status"
            ) (
              .ident "CORTEX_WIRE_STATUS_COMPLETED"
            )
          ) (
            .binary .equal (
              .ident "status"
            ) (
              .ident "CORTEX_WIRE_STATUS_SKIPPED"
            )
          )
        ) [
          .forLoop (
            .assign (
              .ident "cursor"
            ) (
              .index (
                .ident "predecessor_offsets"
              ) (
                .ident "node_id"
              )
            )
          ) (
            .binary .less (
              .ident "cursor"
            ) (
              .index (
                .ident "predecessor_offsets"
              ) (
                .binary .add (
                  .ident "node_id"
                ) (
                  .unsigned 1
                )
              )
            )
          ) (
            .unary .preIncrement (
              .ident "cursor"
            )
          ) [
            .branch (
              .unary .logicalNot (
                .call (
                  .ident "status_unblocks"
                ) [
                  .index (
                    .ident "statuses"
                  ) (
                    .index (
                      .ident "predecessor_nodes"
                    ) (
                      .ident "cursor"
                    )
                  )
                ]
              )
            ) [
              .returnValue (
                .ident "CORTEX_WIRE_ENGINE_STATE_INVALID"
              )
            ] [
            ]
          ]
        ] [
        ]
      ],
      .branch (
        .binary .logicalAnd (
          .binary .equal (
            .pointerField (
              .ident "header"
            ) "terminal"
          ) (
            .ident "CORTEX_WIRE_ENGINE_TERMINAL_COMPLETED"
          )
        ) (
          .parenthesized (
            .binary .logicalOr (
              .unary .logicalNot (
                .ident "settled"
              )
            ) (
              .ident "any_failed"
            )
          )
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_ENGINE_STATE_INVALID"
        )
      ] [
      ],
      .branch (
        .binary .logicalAnd (
          .binary .equal (
            .pointerField (
              .ident "header"
            ) "terminal"
          ) (
            .ident "CORTEX_WIRE_ENGINE_TERMINAL_FAILED"
          )
        ) (
          .unary .logicalNot (
            .ident "any_failed"
          )
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_ENGINE_STATE_INVALID"
        )
      ] [
      ],
      .returnValue (
        .ident "CORTEX_WIRE_ENGINE_STATE_OK"
      )
    ],
    visibility := .internal
  },
  {
    name := "cortex_wire_engine_v1_program_identity",
    result := .pointer (
      .char
    ) true,
    params := [
    ],
    body := some [
      .returnValue (
        .ident "engine_program_identity"
      )
    ],
    visibility := .exported
  },
  {
    name := "engine_request_effect",
    result := .named "cortex_wire_program_v1_effect_result",
    params := [
      {
        name := "node_id",
        ty := .u32
      },
      {
        name := "context",
        ty := .pointer (
          .void
        ) false
      }
    ],
    body := some [
      .local (
        {
          name := "result",
          ty := .named "cortex_wire_program_v1_effect_result",
          initial := none
        }
      ),
      .evaluate (
        .cast (
          .void
        ) (
          .ident "context"
        )
      ),
      .evaluate (
        .call (
          .field (
            .ident "engine_host_api"
          ) "effect_request"
        ) [
          .ident "node_id",
          .field (
            .ident "engine_host_api"
          ) "context"
        ]
      ),
      .assign (
        .field (
          .ident "result"
        ) "kind"
      ) (
        .ident "CORTEX_WIRE_EFFECT_ACCEPTED_ASYNC"
      ),
      .assign (
        .field (
          .ident "result"
        ) "payload_handle"
      ) (
        .unsigned 0
      ),
      .returnValue (
        .ident "result"
      )
    ],
    visibility := .internal
  },
  {
    name := "engine_cancel_effect",
    result := .void,
    params := [
      {
        name := "node_id",
        ty := .u32
      },
      {
        name := "context",
        ty := .pointer (
          .void
        ) false
      }
    ],
    body := some [
      .evaluate (
        .cast (
          .void
        ) (
          .ident "context"
        )
      ),
      .branch (
        .binary .notEqual (
          .field (
            .ident "engine_host_api"
          ) "effect_cancel"
        ) (
          .signed 0
        )
      ) [
        .evaluate (
          .call (
            .field (
              .ident "engine_host_api"
            ) "effect_cancel"
          ) [
            .ident "node_id",
            .field (
              .ident "engine_host_api"
            ) "context"
          ]
        )
      ] [
      ]
    ],
    visibility := .internal
  },
  {
    name := "apply_engine_cancel",
    result := .void,
    params := [
    ],
    body := some [
      .local (
        {
          name := "node_id",
          ty := .u32,
          initial := none
        }
      ),
      .forLoop (
        .assign (
          .ident "node_id"
        ) (
          .unsigned 0
        )
      ) (
        .binary .less (
          .ident "node_id"
        ) (
          .ident "cortex_wire_node_count"
        )
      ) (
        .unary .preIncrement (
          .ident "node_id"
        )
      ) [
        .branch (
          .binary .equal (
            .index (
              .ident "node_status"
            ) (
              .ident "node_id"
            )
          ) (
            .ident "CORTEX_WIRE_STATUS_RUNNING"
          )
        ) [
          .branch (
            .binary .notEqual (
              .field (
                .ident "effect_api"
              ) "effect_cancel"
            ) (
              .signed 0
            )
          ) [
            .evaluate (
              .call (
                .field (
                  .ident "effect_api"
                ) "effect_cancel"
              ) [
                .ident "node_id",
                .field (
                  .ident "effect_api"
                ) "context"
              ]
            )
          ] [
          ],
          .assign (
            .index (
              .ident "node_status"
            ) (
              .ident "node_id"
            )
          ) (
            .ident "CORTEX_WIRE_STATUS_PENDING"
          ),
          .assign (
            .index (
              .ident "output_handle"
            ) (
              .ident "node_id"
            )
          ) (
            .unsigned 0
          )
        ] [
        ]
      ],
      .assign (
        .ident "engine_terminal"
      ) (
        .ident "CORTEX_WIRE_ENGINE_TERMINAL_CANCELLED"
      ),
      .evaluate (
        .unary .preIncrement (
          .ident "engine_checkpoint_sequence"
        )
      ),
      .assign (
        .ident "engine_checkpoint_pending"
      ) (
        .unsigned 1
      )
    ],
    visibility := .internal
  },
  {
    name := "cortex_wire_engine_v1_init",
    result := .int,
    params := [
      {
        name := "api",
        ty := .pointer (
          .named "cortex_wire_engine_v1_host_api"
        ) true
      }
    ],
    body := some [
      .local (
        {
          name := "program_api",
          ty := .named "cortex_wire_program_v1_effect_api",
          initial := none
        }
      ),
      .local (
        {
          name := "result",
          ty := .int,
          initial := none
        }
      ),
      .branch (
        .binary .logicalOr (
          .binary .equal (
            .ident "api"
          ) (
            .signed 0
          )
        ) (
          .binary .equal (
            .pointerField (
              .ident "api"
            ) "effect_request"
          ) (
            .signed 0
          )
        )
      ) [
        .returnValue (
          .unary .negate (
            .signed 1
          )
        )
      ] [
      ],
      .assign (
        .ident "engine_host_api"
      ) (
        .unary .dereference (
          .ident "api"
        )
      ),
      .assign (
        .field (
          .ident "program_api"
        ) "effect_begin"
      ) (
        .ident "engine_request_effect"
      ),
      .assign (
        .field (
          .ident "program_api"
        ) "effect_cancel"
      ) (
        .ident "engine_cancel_effect"
      ),
      .assign (
        .field (
          .ident "program_api"
        ) "context"
      ) (
        .signed 0
      ),
      .assign (
        .ident "result"
      ) (
        .call (
          .ident "cortex_wire_program_v1_init"
        ) [
          .unary .address (
            .ident "program_api"
          )
        ]
      ),
      .branch (
        .binary .notEqual (
          .ident "result"
        ) (
          .signed 0
        )
      ) [
        .returnValue (
          .ident "result"
        )
      ] [
      ],
      .assign (
        .ident "engine_checkpoint_sequence"
      ) (
        .unsigned 1
      ),
      .assign (
        .ident "engine_checkpoint_pending"
      ) (
        .unsigned 1
      ),
      .assign (
        .ident "engine_cancel_requested"
      ) (
        .unsigned 0
      ),
      .assign (
        .ident "engine_terminal"
      ) (
        .ident "CORTEX_WIRE_ENGINE_TERMINAL_ACTIVE"
      ),
      .returnValue (
        .signed 0
      )
    ],
    visibility := .exported
  },
  {
    name := "cortex_wire_engine_v1_drive",
    result := .named "cortex_wire_engine_v1_drive_result",
    params := [
    ],
    body := some [
      .local (
        {
          name := "result",
          ty := .named "cortex_wire_program_v1_drive_result",
          initial := none
        }
      ),
      .branch (
        .binary .logicalOr (
          .binary .equal (
            .ident "initialized"
          ) (
            .unsigned 0
          )
        ) (
          .binary .notEqual (
            .ident "driving"
          ) (
            .unsigned 0
          )
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_ENGINE_DRIVE_ABI_ERROR"
        )
      ] [
      ],
      .branch (
        .binary .notEqual (
          .ident "engine_checkpoint_pending"
        ) (
          .unsigned 0
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_ENGINE_DRIVE_CHECKPOINT_REQUIRED"
        )
      ] [
      ],
      .branch (
        .binary .notEqual (
          .ident "engine_terminal"
        ) (
          .ident "CORTEX_WIRE_ENGINE_TERMINAL_ACTIVE"
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_ENGINE_DRIVE_TERMINAL"
        )
      ] [
      ],
      .assign (
        .ident "result"
      ) (
        .call (
          .ident "cortex_wire_program_v1_drive"
        ) [
        ]
      ),
      .switch (
        .ident "result"
      ) [
        {
          value := .ident "CORTEX_WIRE_DRIVE_AWAITING_COMPLETIONS",
          body := [
            .returnValue (
              .ident "CORTEX_WIRE_ENGINE_DRIVE_AWAITING_COMPLETIONS"
            )
          ]
        },
        {
          value := .ident "CORTEX_WIRE_DRIVE_COMPLETED",
          body := [
            .assign (
              .ident "engine_terminal"
            ) (
              .ident "CORTEX_WIRE_ENGINE_TERMINAL_COMPLETED"
            ),
            .break
          ]
        },
        {
          value := .ident "CORTEX_WIRE_DRIVE_FAILED",
          body := [
            .assign (
              .ident "engine_terminal"
            ) (
              .ident "CORTEX_WIRE_ENGINE_TERMINAL_FAILED"
            ),
            .break
          ]
        },
        {
          value := .ident "CORTEX_WIRE_DRIVE_STUCK",
          body := [
            .returnValue (
              .ident "CORTEX_WIRE_ENGINE_DRIVE_STUCK"
            )
          ]
        },
        {
          value := .ident "CORTEX_WIRE_DRIVE_ABI_ERROR",
          body := [
            .returnValue (
              .ident "CORTEX_WIRE_ENGINE_DRIVE_ABI_ERROR"
            )
          ]
        }
      ] [
        .returnValue (
          .ident "CORTEX_WIRE_ENGINE_DRIVE_ABI_ERROR"
        )
      ],
      .evaluate (
        .unary .preIncrement (
          .ident "engine_checkpoint_sequence"
        )
      ),
      .assign (
        .ident "engine_checkpoint_pending"
      ) (
        .unsigned 1
      ),
      .returnValue (
        .ident "CORTEX_WIRE_ENGINE_DRIVE_CHECKPOINT_REQUIRED"
      )
    ],
    visibility := .exported
  },
  {
    name := "cortex_wire_engine_v1_complete",
    result := .named "cortex_wire_program_v1_completion_result",
    params := [
      {
        name := "node_id",
        ty := .u32
      },
      {
        name := "outcome",
        ty := .named "cortex_wire_program_v1_effect_kind"
      },
      {
        name := "payload",
        ty := .u64
      }
    ],
    body := some [
      .local (
        {
          name := "result",
          ty := .named "cortex_wire_program_v1_completion_result",
          initial := none
        }
      ),
      .branch (
        .binary .logicalOr (
          .binary .notEqual (
            .ident "engine_checkpoint_pending"
          ) (
            .unsigned 0
          )
        ) (
          .binary .notEqual (
            .ident "engine_terminal"
          ) (
            .ident "CORTEX_WIRE_ENGINE_TERMINAL_ACTIVE"
          )
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_COMPLETION_STALE"
        )
      ] [
      ],
      .branch (
        .binary .logicalOr (
          .parenthesized (
            .binary .logicalAnd (
              .binary .equal (
                .ident "outcome"
              ) (
                .ident "CORTEX_WIRE_EFFECT_SUCCESS"
              )
            ) (
              .binary .equal (
                .ident "payload"
              ) (
                .unsigned 0
              )
            )
          )
        ) (
          .parenthesized (
            .binary .logicalAnd (
              .binary .notEqual (
                .ident "outcome"
              ) (
                .ident "CORTEX_WIRE_EFFECT_SUCCESS"
              )
            ) (
              .binary .notEqual (
                .ident "payload"
              ) (
                .unsigned 0
              )
            )
          )
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_COMPLETION_INVALID"
        )
      ] [
      ],
      .assign (
        .ident "result"
      ) (
        .call (
          .ident "cortex_wire_program_v1_complete"
        ) [
          .ident "node_id",
          .ident "outcome",
          .ident "payload"
        ]
      ),
      .branch (
        .binary .equal (
          .ident "result"
        ) (
          .ident "CORTEX_WIRE_COMPLETION_APPLIED"
        )
      ) [
        .evaluate (
          .unary .preIncrement (
            .ident "engine_checkpoint_sequence"
          )
        ),
        .assign (
          .ident "engine_checkpoint_pending"
        ) (
          .unsigned 1
        )
      ] [
      ],
      .returnValue (
        .ident "result"
      )
    ],
    visibility := .exported
  },
  {
    name := "cortex_wire_engine_v1_checkpoint_committed",
    result := .named "cortex_wire_engine_v1_state_result",
    params := [
      {
        name := "checkpoint_sequence",
        ty := .u64
      }
    ],
    body := some [
      .branch (
        .binary .logicalOr (
          .binary .logicalOr (
            .binary .equal (
              .ident "initialized"
            ) (
              .unsigned 0
            )
          ) (
            .binary .equal (
              .ident "engine_checkpoint_pending"
            ) (
              .unsigned 0
            )
          )
        ) (
          .binary .notEqual (
            .ident "checkpoint_sequence"
          ) (
            .ident "engine_checkpoint_sequence"
          )
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_ENGINE_STATE_INVALID"
        )
      ] [
      ],
      .assign (
        .ident "engine_checkpoint_pending"
      ) (
        .unsigned 0
      ),
      .branch (
        .binary .notEqual (
          .ident "engine_cancel_requested"
        ) (
          .unsigned 0
        )
      ) [
        .assign (
          .ident "engine_cancel_requested"
        ) (
          .unsigned 0
        ),
        .evaluate (
          .call (
            .ident "apply_engine_cancel"
          ) [
          ]
        )
      ] [
      ],
      .returnValue (
        .ident "CORTEX_WIRE_ENGINE_STATE_OK"
      )
    ],
    visibility := .exported
  },
  {
    name := "cortex_wire_engine_v1_export_state",
    result := .named "cortex_wire_engine_v1_state_result",
    params := [
      {
        name := "header",
        ty := .pointer (
          .named "cortex_wire_engine_v1_state_header"
        ) false
      },
      {
        name := "statuses",
        ty := .pointer (
          .u8
        ) false
      },
      {
        name := "handles",
        ty := .pointer (
          .u64
        ) false
      },
      {
        name := "capacity",
        ty := .u32
      }
    ],
    body := some [
      .local (
        {
          name := "node_id",
          ty := .u32,
          initial := none
        }
      ),
      .branch (
        .binary .logicalOr (
          .binary .logicalOr (
            .binary .logicalOr (
              .binary .logicalOr (
                .binary .equal (
                  .ident "initialized"
                ) (
                  .unsigned 0
                )
              ) (
                .binary .equal (
                  .ident "header"
                ) (
                  .signed 0
                )
              )
            ) (
              .binary .equal (
                .ident "statuses"
              ) (
                .signed 0
              )
            )
          ) (
            .binary .equal (
              .ident "handles"
            ) (
              .signed 0
            )
          )
        ) (
          .binary .less (
            .ident "capacity"
          ) (
            .ident "cortex_wire_node_count"
          )
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_ENGINE_STATE_INVALID"
        )
      ] [
      ],
      .assign (
        .pointerField (
          .ident "header"
        ) "schema_version"
      ) (
        .ident "CORTEX_WIRE_ENGINE_STATE_SCHEMA_VERSION"
      ),
      .assign (
        .pointerField (
          .ident "header"
        ) "node_count"
      ) (
        .ident "cortex_wire_node_count"
      ),
      .assign (
        .pointerField (
          .ident "header"
        ) "checkpoint_sequence"
      ) (
        .ident "engine_checkpoint_sequence"
      ),
      .assign (
        .pointerField (
          .ident "header"
        ) "terminal"
      ) (
        .ident "engine_terminal"
      ),
      .forLoop (
        .assign (
          .ident "node_id"
        ) (
          .unsigned 0
        )
      ) (
        .binary .less (
          .ident "node_id"
        ) (
          .ident "cortex_wire_node_count"
        )
      ) (
        .unary .preIncrement (
          .ident "node_id"
        )
      ) [
        .assign (
          .index (
            .ident "statuses"
          ) (
            .ident "node_id"
          )
        ) (
          .index (
            .ident "node_status"
          ) (
            .ident "node_id"
          )
        ),
        .assign (
          .index (
            .ident "handles"
          ) (
            .ident "node_id"
          )
        ) (
          .index (
            .ident "output_handle"
          ) (
            .ident "node_id"
          )
        )
      ],
      .returnValue (
        .ident "CORTEX_WIRE_ENGINE_STATE_OK"
      )
    ],
    visibility := .exported
  },
  {
    name := "cortex_wire_engine_v1_import_state",
    result := .named "cortex_wire_engine_v1_state_result",
    params := [
      {
        name := "api",
        ty := .pointer (
          .named "cortex_wire_engine_v1_host_api"
        ) true
      },
      {
        name := "program_identity",
        ty := .pointer (
          .char
        ) true
      },
      {
        name := "header",
        ty := .pointer (
          .named "cortex_wire_engine_v1_state_header"
        ) true
      },
      {
        name := "statuses",
        ty := .pointer (
          .u8
        ) true
      },
      {
        name := "handles",
        ty := .pointer (
          .u64
        ) true
      },
      {
        name := "capacity",
        ty := .u32
      }
    ],
    body := some [
      .local (
        {
          name := "node_id",
          ty := .u32,
          initial := none
        }
      ),
      .local (
        {
          name := "validation",
          ty := .named "cortex_wire_engine_v1_state_result",
          initial := none
        }
      ),
      .branch (
        .binary .logicalOr (
          .binary .logicalOr (
            .binary .logicalOr (
              .binary .equal (
                .ident "api"
              ) (
                .signed 0
              )
            ) (
              .binary .equal (
                .pointerField (
                  .ident "api"
                ) "effect_request"
              ) (
                .signed 0
              )
            )
          ) (
            .binary .notEqual (
              .ident "initialized"
            ) (
              .unsigned 0
            )
          )
        ) (
          .binary .notEqual (
            .ident "driving"
          ) (
            .unsigned 0
          )
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_ENGINE_STATE_INVALID"
        )
      ] [
      ],
      .assign (
        .ident "validation"
      ) (
        .call (
          .ident "engine_validate_state"
        ) [
          .ident "program_identity",
          .ident "header",
          .ident "statuses",
          .ident "handles",
          .ident "capacity"
        ]
      ),
      .branch (
        .binary .notEqual (
          .ident "validation"
        ) (
          .ident "CORTEX_WIRE_ENGINE_STATE_OK"
        )
      ) [
        .returnValue (
          .ident "validation"
        )
      ] [
      ],
      .assign (
        .ident "engine_host_api"
      ) (
        .unary .dereference (
          .ident "api"
        )
      ),
      .assign (
        .field (
          .ident "effect_api"
        ) "effect_begin"
      ) (
        .ident "engine_request_effect"
      ),
      .assign (
        .field (
          .ident "effect_api"
        ) "effect_cancel"
      ) (
        .ident "engine_cancel_effect"
      ),
      .assign (
        .field (
          .ident "effect_api"
        ) "context"
      ) (
        .signed 0
      ),
      .forLoop (
        .assign (
          .ident "node_id"
        ) (
          .unsigned 0
        )
      ) (
        .binary .less (
          .ident "node_id"
        ) (
          .ident "cortex_wire_node_count"
        )
      ) (
        .unary .preIncrement (
          .ident "node_id"
        )
      ) [
        .assign (
          .index (
            .ident "node_status"
          ) (
            .ident "node_id"
          )
        ) (
          .index (
            .ident "statuses"
          ) (
            .ident "node_id"
          )
        ),
        .assign (
          .index (
            .ident "output_handle"
          ) (
            .ident "node_id"
          )
        ) (
          .index (
            .ident "handles"
          ) (
            .ident "node_id"
          )
        ),
        .assign (
          .index (
            .ident "frontier_snapshot"
          ) (
            .ident "node_id"
          )
        ) (
          .unsigned 0
        )
      ],
      .assign (
        .ident "terminal_failed"
      ) (
        .cast (
          .u8
        ) (
          .parenthesized (
            .binary .equal (
              .pointerField (
                .ident "header"
              ) "terminal"
            ) (
              .ident "CORTEX_WIRE_ENGINE_TERMINAL_FAILED"
            )
          )
        )
      ),
      .assign (
        .ident "engine_checkpoint_sequence"
      ) (
        .pointerField (
          .ident "header"
        ) "checkpoint_sequence"
      ),
      .assign (
        .ident "engine_checkpoint_pending"
      ) (
        .unsigned 1
      ),
      .comment
        [ "The cancel latch is session state, not exported state: a deferred"
        , "cancel does not survive export/import. The host re-issues the cancel"
        , "after a restore because the cancellation request itself is durable"
        , "on the host side."
        ],
      .assign (
        .ident "engine_cancel_requested"
      ) (
        .unsigned 0
      ),
      .assign (
        .ident "engine_terminal"
      ) (
        .pointerField (
          .ident "header"
        ) "terminal"
      ),
      .assign (
        .ident "initialized"
      ) (
        .unsigned 1
      ),
      .returnValue (
        .ident "CORTEX_WIRE_ENGINE_STATE_OK"
      )
    ],
    visibility := .exported
  },
  {
    name := "cortex_wire_engine_v1_cancel",
    result := .named "cortex_wire_engine_v1_state_result",
    params := [
    ],
    body := some [
      .branch (
        .binary .logicalOr (
          .binary .logicalOr (
            .binary .equal (
              .ident "initialized"
            ) (
              .unsigned 0
            )
          ) (
            .binary .notEqual (
              .ident "driving"
            ) (
              .unsigned 0
            )
          )
        ) (
          .binary .notEqual (
            .ident "engine_terminal"
          ) (
            .ident "CORTEX_WIRE_ENGINE_TERMINAL_ACTIVE"
          )
        )
      ) [
        .returnValue (
          .ident "CORTEX_WIRE_ENGINE_STATE_INVALID"
        )
      ] [
      ],
      .branch (
        .binary .notEqual (
          .ident "engine_checkpoint_pending"
        ) (
          .unsigned 0
        )
      ) [
        .assign (
          .ident "engine_cancel_requested"
        ) (
          .unsigned 1
        ),
        .returnValue (
          .ident "CORTEX_WIRE_ENGINE_STATE_CANCEL_DEFERRED"
        )
      ] [
      ],
      .evaluate (
        .call (
          .ident "apply_engine_cancel"
        ) [
        ]
      ),
      .returnValue (
        .ident "CORTEX_WIRE_ENGINE_STATE_OK"
      )
    ],
    visibility := .exported
  },
  {
    name := "cortex_wire_engine_v1_terminal",
    result := .named "cortex_wire_engine_v1_terminal_state",
    params := [
    ],
    body := some [
      .returnValue (
        .ident "engine_terminal"
      )
    ],
    visibility := .exported
  }
]

end Cortex.Wire.StaticCEmitter
