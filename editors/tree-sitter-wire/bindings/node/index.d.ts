// TypeScript declarations for tree-sitter-wire.
// Consumed by editors/tooling that bind tree-sitter grammars through a typed
// Node API (e.g. web-tree-sitter, node-tree-sitter with TypeScript).

type BaseNode = {
  type: string;
  named: boolean;
};

type ChildNode = {
  multiple: boolean;
  required: boolean;
  types: BaseNode[];
};

type NodeInfo =
  | (BaseNode & { subtypes: BaseNode[] })
  | (BaseNode & {
      fields: { [name: string]: ChildNode };
      children: ChildNode[];
    });

type Language = {
  name: string;
  language: unknown;
  nodeTypeInfo: NodeInfo[];
};

declare const language: Language;
export = language;
