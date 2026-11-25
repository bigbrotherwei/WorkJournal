import { Plugin, PluginKey } from '@tiptap/pm/state';
import { Decoration, DecorationSet } from '@tiptap/pm/view';
import { closeHistory } from '@tiptap/pm/history';
import { Fragment, Mark } from '@tiptap/pm/model';
import { Step, StepResult, StepMap } from '@tiptap/pm/transform';

export function documentOutline(doc) {
  const result=[];
  doc.descendants((node,position)=>{if(node.type.name==='heading')result.push({position,level:node.attrs.level,text:node.textContent || '无标题'});});
  return result;
}
export function textMatches(text, query) {
  if(!query)return [];
  // Match the original string so Unicode case conversion cannot shift selection offsets.
  const literal=query.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
  return Array.from(text.matchAll(new RegExp(literal,'giu')),match=>({from:match.index,to:match.index+match[0].length}));
}
export function documentMatches(doc,query) {
  if(!query)return [];
  const result=[];
  doc.descendants((node,position)=>{
    if(!node.isTextblock)return;
    let text='',start=position+1;
    const collect=()=>{for(const range of textMatches(text,query))result.push({from:start+range.from,to:start+range.to});text='';};
    node.forEach((child,offset)=>{if(child.isText)text+=child.text;else {collect();start=position+1+offset+child.nodeSize;}});
    collect();return false;
  });
  return result;
}
export function replaceMatches(editor,query,replacement,all=false,index=0) {
  if(!editor.isEditable || editor.view.composing)return 0;
  const matches=documentMatches(editor.state.doc,query);
  const selected=all?matches:(matches[index]?[matches[index]]:[]);
  if(!selected.length)return 0;
  let tr=closeHistory(editor.state.tr);
  for(const match of selected.slice().reverse()) {
    if(replacement) {
      // Retain corresponding rich-text runs, even when a query spans adjacent marks.
      const styles=[];
      editor.state.doc.nodesBetween(match.from,match.to,(node,position)=>{
        if(node.isText)for(const character of Array.from(node.text.slice(Math.max(0,match.from-position),Math.min(node.text.length,match.to-position))))styles.push(node.marks);
      });
      const characters=Array.from(replacement), runs=[];
      for(let i=0;i<characters.length;i++) {
        const marks=styles[Math.min(styles.length-1,Math.floor(i*styles.length/characters.length))] || [];
        const last=runs.at(-1);
        if(last && Mark.sameSet(last.marks,marks))last.text+=characters[i];else runs.push({text:characters[i],marks});
      }
      tr=tr.replaceWith(match.from,match.to,Fragment.fromArray(runs.map(run=>editor.schema.text(run.text,run.marks))));
    }
    else tr=tr.delete(match.from,match.to);
  }
  editor.view.dispatch(tr);editor.view.dispatch(closeHistory(editor.state.tr));return selected.length;
}
// A reversible source snapshot travels in the same history event as document steps.
// It preserves Markdown whitespace/syntax that the rendered schema cannot represent.
export class MarkdownSourceStep extends Step {
  constructor(before,after){super();this.before=before;this.after=after;}
  apply(doc){return StepResult.ok(doc);}
  invert(){return new MarkdownSourceStep(this.after,this.before);}
  map(){return this;}
  getMap(){return StepMap.empty;}
  toJSON(){return {stepType:'notebookMarkdownSource',before:this.before,after:this.after};}
  static fromJSON(_schema,json){return new MarkdownSourceStep(json.before,json.after);}
}
Step.jsonID('notebookMarkdownSource',MarkdownSourceStep);
export const sourceKey = new PluginKey('notebookMarkdownSource');
export const searchKey = new PluginKey('notebookSearch');
export function workflowPlugins(editor) {
  return [new Plugin({filterTransaction:tr=>!tr.docChanged || editor.isEditable}),new Plugin({
    key:sourceKey,
    state:{init:()=>null,apply:(tr,source)=>{
      const step=tr.steps.findLast(step=>step instanceof MarkdownSourceStep);
      const sourceTransaction=tr.getMeta('appendedTransaction')?.steps.some(step=>step instanceof MarkdownSourceStep);
      // Schema normalization (for example a trailing paragraph) belongs to the
      // source transaction and must not erase the source it just recorded.
      return step?step.after:(tr.docChanged&&!sourceTransaction?null:source);
    }},
    appendTransaction(transactions,oldState,newState){
      const source=sourceKey.getState(oldState);
      if(source==null || !transactions.some(tr=>tr.docChanged) || transactions.some(tr=>tr.steps.some(step=>step instanceof MarkdownSourceStep)))return null;
      // Rich-text edits invalidate raw source, while undo restores that exact source.
      return newState.tr.step(new MarkdownSourceStep(source,null));
    }
  }),new Plugin({
    key:searchKey,
    state:{init:()=>'',apply:(tr,query)=>tr.getMeta(searchKey) ?? query},
    props:{decorations(state){const query=searchKey.getState(state);return DecorationSet.create(state.doc,documentMatches(state.doc,query).map(range=>Decoration.inline(range.from,range.to,{class:'search-match'})));}}
  })];
}
