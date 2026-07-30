// Entry for the vendored CodeMirror 6 bundle. Exports exactly what the owned-file
// editor needs: editor core, JSON + XML languages, and the unified/merge diff view.
export { EditorView, keymap, lineNumbers } from '@codemirror/view';
export { EditorState, Compartment } from '@codemirror/state';
export { basicSetup } from 'codemirror';
export { json } from '@codemirror/lang-json';
export { xml } from '@codemirror/lang-xml';
export { MergeView, unifiedMergeView } from '@codemirror/merge';
