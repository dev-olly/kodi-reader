import { acceptCompletion, autocompletion, closeCompletion, pickedCompletion, type Completion, type CompletionContext, type CompletionResult, type CompletionSource } from '@codemirror/autocomplete';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { EditorState, Prec, Transaction, type Extension } from '@codemirror/state';
import { keymap, type EditorView } from '@codemirror/view';

export type NoteCommand = 'sketch' | 'audio' | 'remind';
type RunCommand = (name: NoteCommand, argument: string) => void;
interface CommandDefinition { name: NoteCommand; aliases: readonly string[]; detail: string }
const commands: readonly CommandDefinition[] = [
  { name: 'sketch', aliases: ['sketch', 'draw'], detail: 'Add a sketch' },
  { name: 'audio', aliases: ['audio'], detail: 'Record an audio note' },
  { name: 'remind', aliases: ['remind', 'task'], detail: 'Add a research reminder' },
];

interface CommandLine {
  from: number;
  to: number;
  slash: number;
  token: string;
  argument: string;
  hasArgument: boolean;
}

function commandLine(state: EditorState, position: number): CommandLine | null {
  if (state.readOnly || state.selection.ranges.length !== 1 || !state.selection.main.empty) return null;
  const line = state.doc.lineAt(position);
  // Slash commands occupy their own line. Enter in prose or in the middle of
  // a line remains ordinary Markdown editing, never a destructive command.
  if (position !== line.to) return null;
  const match = /^([ \t]*)\/([a-z]*)(?:[ \t]+(.*))?$/i.exec(line.text);
  if (!match) return null;
  const slash = line.from + match[1].length;
  const tree = ensureSyntaxTree(state, Math.min(state.doc.length, slash + 1), 25) ?? syntaxTree(state);
  // If parsing has not reached the command, fail closed rather than execute
  // an example inside a code block while the background parse catches up.
  if (tree.length < slash + 1) return null;
  for (let node: ReturnType<typeof tree.resolveInner> | null = tree.resolveInner(slash + 1, -1); node; node = node.parent) {
    if (['FencedCode', 'CodeBlock', 'InlineCode', 'CodeText', 'HTMLBlock'].includes(node.name)) return null;
  }
  return {
    from: line.from,
    to: line.to,
    slash,
    token: match[2].toLowerCase(),
    argument: (match[3] || '').trim(),
    hasArgument: Boolean(match[3]?.trim()),
  };
}

function candidates(line: CommandLine): readonly CommandDefinition[] {
  return commands.filter(command => command.aliases.some(alias => alias.startsWith(line.token)) &&
    (!line.hasArgument || command.name === 'remind' && command.aliases.includes(line.token)));
}

function execute(view: EditorView, line: CommandLine, definition: CommandDefinition, run: RunCommand, completion?: Completion): void {
  view.dispatch({
    changes: { from: line.from, to: line.to, insert: '' },
    selection: { anchor: line.from },
    annotations: [Transaction.userEvent.of('input.note-command'), ...(completion ? [pickedCompletion.of(completion)] : [])],
  });
  closeCompletion(view);
  run(definition.name, definition.name === 'remind' ? line.argument : '');
}

/**
 * A slash picker and Enter binding for a Markdown note. The host owns async
 * action progress/errors; this extension only consumes recognized command text.
 */
export function noteCommandExtensions(run: RunCommand): Extension {
  const source: CompletionSource = (context: CompletionContext): CompletionResult | null => {
    const line = commandLine(context.state, context.pos);
    if (!line) return null;
    const options = candidates(line).map((definition): Completion => ({
      label: `/${definition.name}`,
      detail: definition.detail,
      type: 'keyword',
      section: 'Add to note',
      apply(view, completion) {
        // Re-read current state: the picker may have opened before further
        // typing, cursor movement, or a controlled note update.
        const current = commandLine(view.state, view.state.selection.main.head);
        if (!current || !candidates(current).includes(definition)) return;
        execute(view, current, definition, run, completion);
      },
    }));
    return options.length ? { from: line.slash, to: line.to, options, filter: false } : null;
  };
  return [
    EditorState.languageData.of(() => [{ autocomplete: source }]),
    Prec.highest(keymap.of([{ key: 'Enter', run(view) {
      // Honor ArrowUp/Down selection and partial prefixes in the open picker.
      if (acceptCompletion(view)) return true;
      const line = commandLine(view.state, view.state.selection.main.head);
      if (!line) return false;
      const definition = candidates(line).find(command => command.aliases.includes(line.token));
      if (!definition) return false;
      execute(view, line, definition, run);
      return true;
    } }])),
    autocompletion({ activateOnTyping: true, activateOnTypingDelay: 0, interactionDelay: 0, selectOnOpen: true, maxRenderedOptions: 3 }),
  ];
}
