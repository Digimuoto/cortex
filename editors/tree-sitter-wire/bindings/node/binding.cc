// Node binding for tree-sitter-wire.
// Exposes the `tree_sitter_wire` language function (generated in src/parser.c)
// to Node via N-API, so `require("tree-sitter-wire")` returns a Language
// consumable by `node-tree-sitter`.
//
// Follows the conventional shape emitted by `tree-sitter init` (tree-sitter
// CLI 0.24+). Name + Language external; no custom TypeTag to keep the binding
// portable across napi-addon-api minor versions.

#include <napi.h>

typedef struct TSLanguage TSLanguage;

extern "C" TSLanguage *tree_sitter_wire();

Napi::Object Init(Napi::Env env, Napi::Object exports) {
  exports["name"] = Napi::String::New(env, "wire");
  exports["language"] =
      Napi::External<TSLanguage>::New(env, tree_sitter_wire());
  return exports;
}

NODE_API_MODULE(tree_sitter_wire_binding, Init)
