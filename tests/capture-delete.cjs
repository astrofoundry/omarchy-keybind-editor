// Exercise the real capture handler without a compositor or a live keymap.
// Run: node tests/capture-delete.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'KeybindEditor.qml'), 'utf8');
const handler = source.slice(source.indexOf('  function handleCaptureKey(event)'), source.indexOf('  function applyCapture()'));
assert.match(handler, /function handleCaptureKey\(event\)/);
const Qt = {Key_Escape: 1, Key_Return: 2, Key_Enter: 3, Key_Backspace: 4, Key_F2: 5, Key_Delete: 6};
const model = {};
vm.createContext(model);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'KeybindModel.js'), 'utf8').replace(/^\.pragma library\s*$/m, ''), Object.assign(model, {Qt}));

for (const adding of [false, true]) {
  let applied = 0;
  const root = {
    applying: false, deleteConfirm: false, addOpen: adding, altgrHeld: false,
    isAltgrEvent: () => false,
    enterDeleteConfirm: () => assert.fail('Delete in the recorder requested removal'),
    applyDelete: () => assert.fail('Recording a shortcut removed the binding'),
    updateConflict() {},
    applyCapture: () => applied++, advanceAdd: () => applied++,
  };
  const context = {Qt, root, KeybindModel: model};
  vm.createContext(context);
  vm.runInContext(handler, context);
  context.handleCaptureKey({key: Qt.Key_Delete, modifiers: 0, nativeScanCode: 119, text: ''});
  assert.equal(root.deleteConfirm, false);
  assert.equal(root.capturedKeyToken, 'code:119');
  assert.equal(root.capturedKeyLabel, 'Delete');
  context.handleCaptureKey({key: Qt.Key_Return, modifiers: 0, text: ''});
  assert.equal(applied, 1);
}
console.log('Delete is recorded in Change and Add; Enter applies instead of deleting.');
