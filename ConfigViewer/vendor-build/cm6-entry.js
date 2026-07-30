// Entry for the vendored CodeMirror 6 bundle. Exports exactly what the owned-file
// editor needs: editor core, JSON + XML languages, the unified/merge diff view, and
// the highlight primitives so tokens can be mapped onto the app's OWN t-* palette
// classes (style.css) instead of CM's default light theme.
export { EditorView, keymap, lineNumbers } from '@codemirror/view';
export { EditorState, Compartment } from '@codemirror/state';
export { basicSetup } from 'codemirror';
export { json } from '@codemirror/lang-json';
export { xml } from '@codemirror/lang-xml';
export { MergeView, unifiedMergeView } from '@codemirror/merge';
export { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
export { tags } from '@lezer/highlight';
