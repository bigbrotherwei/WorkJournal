import { Editor, Extension, Node as TiptapNode } from '@tiptap/core';
import { DOMSerializer } from '@tiptap/pm/model';
import StarterKit from '@tiptap/starter-kit';
import { Markdown } from '@tiptap/markdown';
import Image from '@tiptap/extension-image';
import { TableKit } from '@tiptap/extension-table';
import TaskList from '@tiptap/extension-task-list';
import TaskItem from '@tiptap/extension-task-item';
import { TextStyle, Color, BackgroundColor } from '@tiptap/extension-text-style';
import TextAlign from '@tiptap/extension-text-align';
import Highlight from '@tiptap/extension-highlight';
import Subscript from '@tiptap/extension-subscript';
import Superscript from '@tiptap/extension-superscript';
import CodeBlockLowlight from '@tiptap/extension-code-block-lowlight';
import { common, createLowlight } from 'lowlight';
import createDOMPurify from 'dompurify';

export const MAX_TEXT = 8 * 1024 * 1024;
const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const notePattern = new RegExp(`^workjournal-note://(${uuid})$`, 'i');
const assetPattern = new RegExp(`^workjournal-asset://(${uuid})/(${uuid})$`, 'i');
export function safeURL(value, noteID, imageOnly = false) {
  if (typeof value !== 'string' || value.length > 4096 || /[\u0000-\u0020\u007f]/.test(value)) return null;
  const match = assetPattern.exec(value);
  if (match) return match[1].toLowerCase() === noteID.toLowerCase() ? value : null;
  if (imageOnly) return null;
  if (notePattern.test(value)) return value;
  try { const url = new URL(value); return ['https:','http:','mailto:'].includes(url.protocol) && !url.username && !url.password ? value : null; } catch { return null; }
}
export function sanitizeHTML(html, noteID) {
  const purifier = createDOMPurify(window);
  purifier.addHook('uponSanitizeAttribute', (node, data) => {
    if (data.attrName === 'href' || data.attrName === 'src') data.keepAttr = !!safeURL(data.attrValue, noteID, data.attrName === 'src');
    if (data.attrName === 'style') {
      const probe = document.createElement('span'); probe.setAttribute('style',data.attrValue);
      data.attrValue = ['color','background-color','text-align'].map(name => {
        const val = probe.style.getPropertyValue(name); return val && !/url|expression|var\(/i.test(val) ? `${name}:${val}` : '';
      }).filter(Boolean).join(';');
    }
  });
  return purifier.sanitize(html, { ALLOWED_TAGS:['p','br','h1','h2','h3','h4','h5','h6','strong','b','em','i','s','del','u','code','pre','blockquote','ul','ol','li','hr','table','tbody','thead','tr','th','td','a','img','span','mark','sub','sup','label','input','div'], ALLOWED_ATTR:['href','src','alt','title','style','colspan','rowspan','colwidth','align','start','data-type','data-checked','data-color','type','checked','class'], ALLOW_DATA_ATTR:false, ADD_URI_SAFE_ATTR:[], ALLOWED_URI_REGEXP:/^(?:(?:https?|mailto|workjournal-asset|workjournal-note):)/i });
}
function cleanJSON(node, noteID) {
  if (!node || typeof node !== 'object') return node;
  if (node.type === 'image' && !safeURL(node.attrs?.src,noteID,true)) return {type:'text',text:`[图片未加载：${node.attrs?.alt || node.attrs?.src || '无地址'}]`};
  if (node.marks) {
    node.marks = node.marks.filter(mark => mark.type !== 'link' || safeURL(mark.attrs?.href,noteID));
    for (const mark of node.marks) for (const key of ['color','backgroundColor']) {
      if (mark.attrs?.[key]) { const probe=document.createElement('span'); probe.style.color=mark.attrs[key]; mark.attrs[key]=probe.style.color || null; }
    }
  }
  if (node.content) node.content = node.content.map(child => cleanJSON(child,noteID));
  return node;
}
const PreservedBlock = TiptapNode.create({
  name:'preservedBlock', group:'block', atom:true,
  addAttributes(){return {source:{default:''}};},
  parseHTML(){return [{tag:'pre[data-preserved-source]',getAttrs:element=>({source:element.getAttribute('data-preserved-source')})}];},
  renderHTML({node}){return ['pre',{'data-preserved-source':node.attrs.source,class:'preserved'},node.attrs.source];},
  renderMarkdown(node){return node.attrs.source;},
  parseMarkdown(token,h){return h.createNode('preservedBlock',{source:token.raw.trimEnd()});},
  markdownTokenizer:{name:'preservedBlock',level:'block',start:source=>source.search(/^\[\^[^\]]+\]:/m),tokenize(source){const match=/^\[\^[^\]]+\]:[^\n]*(?:\n(?:[ \t]+[^\n]*|(?=\n[ \t])))*\n?/.exec(source);if(match)return {type:'preservedBlock',raw:match[0]};}}
});
// Preserve HTML the schema cannot represent as visible, inert source nodes.
// Tiptap's built-in HTML fallback drops comments and misses hyphenated tag names.
const supportedHTMLTags = new Set(['p','br','h1','h2','h3','h4','h5','h6','strong','b','em','i','s','del','u','code','pre','blockquote','ul','ol','li','hr','table','tbody','thead','tfoot','colgroup','col','tr','th','td','a','img','span','mark','sub','sup','label','input','div']);
const removedHTMLTags = new Set(['script','style','iframe','object','embed','link','meta','base']);
function containsUnsupportedHTML(raw) {
  if (/<!--|<!\[CDATA\[|<\?/.test(raw)) return true;
  return Array.from(raw.matchAll(/<\/?([a-z][\w:-]*)\b/gi)).some(([,tag])=>!supportedHTMLTags.has(tag.toLowerCase()) && !removedHTMLTags.has(tag.toLowerCase()));
}
const PreservedHTML = Extension.create({
  name:'preservedHTML', markdownTokenName:'html',
  parseMarkdown(token,h) {
    const source=token.raw || token.text || '';
    return containsUnsupportedHTML(source) ? h.createNode('preservedBlock',{source:source.trimEnd()}) : null;
  }
});
const PreservedInline = TiptapNode.create({
  name:'preservedInline', priority:1000, group:'inline', inline:true, atom:true, marks:'',
  addAttributes(){return {source:{default:''}};},
  parseHTML(){return [{tag:'span[data-preserved-inline]',getAttrs:element=>({source:element.getAttribute('data-preserved-inline')})}];},
  renderHTML({node}){return ['span',{'data-preserved-inline':node.attrs.source,class:'preserved-inline'},node.attrs.source];},
  renderMarkdown(node){return node.attrs.source;},
  parseMarkdown(token,h){return h.createNode('preservedInline',{source:token.raw});},
  markdownTokenizer:{name:'preservedInline',level:'inline',start:source=>source.indexOf('<'),tokenize(source){
    const match=/^(?:<!--[\s\S]*?(?:-->|$)|<\/?[a-z][\w:-]*\b(?:[^"'<>]|"[^"]*"|'[^']*')*>)/i.exec(source);
    if(match && containsUnsupportedHTML(match[0]))return {type:'preservedInline',raw:match[0]};
  }}
});
const SafeCodeBlock = CodeBlockLowlight.extend({
  renderMarkdown(node,h) {
    const text=h.renderChildren(node.content || []);
    let longest=0;
    for(const match of text.matchAll(/`+/g))longest=Math.max(longest,match[0].length);
    const fence='`'.repeat(Math.max(3,longest+1));
    return `${fence}${node.attrs?.language || ''}\n${text}\n${fence}`;
  }
});
function needsHTML(node) {
  if (node.type === 'table') {
    const header=node.content?.[0]?.content || [];
    if (!header.every(cell=>cell.type==='tableHeader')) return true;
    if (node.content?.slice(1).some(row=>row.content?.some((cell,index)=>cell.type==='tableHeader' || (cell.attrs?.align || null)!==(header[index]?.attrs?.align || null)))) return true;
  }
  if (['tableCell','tableHeader'].includes(node.type) && (node.content?.length !== 1 || node.content?.[0]?.type !== 'paragraph')) return true;
  if (node.attrs?.textAlign || node.attrs?.colspan > 1 || node.attrs?.rowspan > 1 || node.attrs?.colwidth || (node.type === 'image' && (node.attrs?.width || node.attrs?.height || /[\[\]\"<>\n]/.test((node.attrs?.alt || '') + (node.attrs?.title || ''))))) return true;
  if (node.marks?.some(m => ['textStyle','underline','highlight','subscript','superscript'].includes(m.type) || (m.type==='link' && (m.attrs?.title || /[()\\]/.test(m.attrs?.href || ''))))) return true;
  return node.content?.some(needsHTML) || false;
}
function escapedHTML(node) {
  const escape = value => value.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  if (node.nodeType===3) return escape(node.nodeValue || '');
  const tag=node.tagName.toLowerCase();
  const attrs=Array.from(node.attributes).map(a=>` ${a.name}="${escape(a.value)}"`).join('');
  return `<${tag}${attrs}>` + (['img','br','hr','input','col'].includes(tag) ? '' : Array.from(node.childNodes).map(escapedHTML).join('') + `</${tag}>`);
}
export function createEditor({markdown = '', noteID, element, onUpdate = () => {}, editorProps = {}}) {
  const editor = new Editor({element,extensions:[PreservedBlock,PreservedHTML,PreservedInline,StarterKit.configure({codeBlock:false,link:{openOnClick:false,autolink:false,isAllowedUri:url=>!!safeURL(url,noteID)}}),Markdown,Image.configure({inline:true}),TableKit.configure({table:{resizable:false}}),TaskList,TaskItem.configure({nested:true}),TextStyle,Color,BackgroundColor,TextAlign.configure({types:['heading','paragraph']}),Highlight.configure({multicolor:true}),Subscript,Superscript,SafeCodeBlock.configure({lowlight:createLowlight(common)})], content:'',editorProps:{attributes:{'aria-label':'笔记正文',role:'textbox','aria-multiline':'true'},...editorProps,transformPastedHTML:html=>sanitizeHTML(html,noteID)}, onUpdate});
  // Parse into inert schema data before mounting any nodes; no raw HTML enters the live editor.
  const parse = text => cleanJSON(editor.markdown.parse(text),noteID);
  editor.loadMarkdown = text => editor.chain().setContent(parse(text),{emitUpdate:false}).setMeta('addToHistory',false).run();
  editor.loadMarkdown(markdown);
  editor.getMarkdown = () => {
    const serializer = DOMSerializer.fromSchema(editor.schema);
    const result = [];
    editor.state.doc.forEach(node => {
      const json = node.toJSON();
      if (needsHTML(json)) result.push(escapedHTML(serializer.serializeNode(node)));
      else result.push(editor.markdown.serialize({type:'doc',content:[json]}));
    });
    return result.join('\n\n');
  };
  return editor;
}
export class SessionState {
  constructor(noteID,sessionID,sequence,markdown) { this.noteID=noteID;this.sessionID=sessionID;this.sequence=sequence;this.markdown=markdown;this.composing=false;this.waiters=[]; }
  accepts(message) { return message?.noteID===this.noteID && message.sessionID===this.sessionID && Number.isSafeInteger(message.sequence) && message.sequence>=this.sequence && message.sequence<Number.MAX_SAFE_INTEGER; }
  current() { return this.markdown; }
  edit(markdown) { if (new TextEncoder().encode(markdown).length>MAX_TEXT) throw new Error('笔记超过 8 MiB，当前内容尚未保存'); if(markdown!==this.markdown){this.markdown=markdown;this.sequence++;} }
  endComposition() { this.composing=false; const pending=this.waiters.splice(0);for(const done of pending) done(); }
  async flush(read) { if(this.composing) await new Promise(resolve=>this.waiters.push(resolve)); return read(); }
  message(type,extra={}) { return {type,noteID:this.noteID,sessionID:this.sessionID,sequence:this.sequence,...extra}; }
}
