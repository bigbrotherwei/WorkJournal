// Local SVG paths keep toolbar controls crisp, consistent and entirely offline.
const icons = {
  bold:'<path d="M8 4h5a4 4 0 0 1 0 8H8zm0 8h6a4 4 0 0 1 0 8H8z"/>',
  italic:'<path d="M11 4h8M5 20h8M15 4 9 20"/>',
  underline:'<path d="M6 4v7a6 6 0 0 0 12 0V4M5 21h14"/>',
  strike:'<path d="M17 6c-1-2-3-3-5-3-3 0-5 2-5 4 0 2 2 3 5 4m-5 7c1 2 3 3 5 3 3 0 5-2 5-4 0-1-1-2-2-3M3 12h18"/>',
  code:'<path d="m8 7-5 5 5 5m8-10 5 5-5 5m-3-13-2 16"/>',
  subscript:'<path d="m4 5 9 11M13 5 4 16M16 15a2 2 0 0 1 4 0c0 2-4 3-4 6h4"/>',
  superscript:'<path d="m4 8 9 11M13 8 4 19M16 5a2 2 0 0 1 4 0c0 2-4 3-4 6h4"/>',
  bulletList:'<circle cx="4" cy="6" r="1"/><circle cx="4" cy="12" r="1"/><circle cx="4" cy="18" r="1"/><path d="M9 6h12M9 12h12M9 18h12"/>',
  orderedList:'<path d="M3 4h1v5M3 9h2M2 15c0-3 4-3 4-1 0 2-4 3-4 6h4M10 6h11M10 12h11M10 18h11"/>',
  taskList:'<rect x="3" y="4" width="6" height="6" rx="1.2"/><path d="m4 7 1.5 1.5L8 6M13 7h8M13 17h8"/><rect x="3" y="14" width="6" height="6" rx="1.2"/>',
  blockquote:'<path d="M5 6h5v6H6c0 3-1 4-3 5M15 6h5v6h-4c0 3-1 4-3 5"/>',
  codeBlock:'<rect x="2" y="4" width="20" height="16" rx="3"/><path d="m8 9-3 3 3 3m8-6 3 3-3 3m-3-8-2 10"/>',
  horizontalRule:'<path d="M3 12h18"/>',
  link:'<path d="m10 13 4-4m-6 6-2 2a4 4 0 0 1-6-6l4-4a4 4 0 0 1 6 0m4 2 2-2a4 4 0 1 1 6 6l-4 4a4 4 0 0 1-6 0" transform="translate(1 0)"/>',
  image:'<rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8" cy="8" r="1.5"/><path d="m3 17 5-5 4 4 4-6 5 7"/>',
  table:'<rect x="3" y="3" width="18" height="18" rx="3"/><path d="M3 9h18M3 15h18M9 3v18M15 3v18"/>',
  imageEdit:'<rect x="3" y="3" width="15" height="15" rx="3"/><path d="m3 15 5-5 4 4m4 8 6-6-3-3-6 6-1 4z"/>',
  undo:'<path d="m8 4-5 5 5 5M3 9h10a7 7 0 0 1 0 14" transform="translate(0 -2)"/>',
  redo:'<path d="m16 4 5 5-5 5m5-5H11a7 7 0 0 0 0 14" transform="translate(0 -2)"/>',
  clear:'<path d="m4 15 9-11 7 6-9 11H7zm7-9 7 6M11 21h10"/>',
  more:'<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>'
};
function icon(name) {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${icons[name] || icons.more}</svg>`;
}
export function buildToolbar({container,getEditor,commands}) {
  const main=document.createElement('div');main.id='toolbar-main';main.className='toolbar-main';container.append(main);
  const advanced=document.createElement('div');advanced.id='toolbar-advanced';advanced.className='toolbar-advanced';advanced.hidden=true;advanced.setAttribute('role','group');advanced.setAttribute('aria-label','更多格式');container.append(advanced);
  function group(parent,label,caption=false) {
    const group=document.createElement('div');group.className='toolbar-group';group.setAttribute('role','group');group.setAttribute('aria-label',label);
    if(caption){const text=document.createElement('span');text.className='toolbar-caption';text.textContent=label;group.append(text);}
    parent.append(group);return group;
  }
  function button(parent,name,label) {
    const button=document.createElement('button');button.type='button';button.className='toolbar-button';button.title=label;button.setAttribute('aria-label',label);button.dataset.command=name;button.innerHTML=icon(name);
    button.onmousedown=event=>event.preventDefault();button.onclick=()=>{if(getEditor())commands[name]?.();};parent.append(button);return button;
  }
  function select(parent,label,items,handler,iconName) {
    const wrap=document.createElement('div');wrap.className=iconName?'toolbar-select icon-select':'toolbar-select';if(iconName)wrap.innerHTML=icon(iconName);
    const select=document.createElement('select');select.title=label;select.setAttribute('aria-label',label);
    for(const [value,text]of items){const option=document.createElement('option');option.value=value;option.textContent=text;select.append(option);}
    select.onchange=()=>{if(getEditor())handler(select.value,select);};wrap.append(select);parent.append(wrap);return select;
  }
  const paragraph=group(main,'段落样式');
  const heading=select(paragraph,'段落样式',[['0','正文'],...Array.from({length:6},(_,i)=>[String(i+1),`标题 ${i+1}`])],value=>value==='0'?getEditor().chain().focus().setParagraph().run():getEditor().chain().focus().toggleHeading({level:Number(value)}).run());
  const text=group(main,'文字格式');for(const [name,label]of [['bold','加粗 ⌘B'],['italic','斜体 ⌘I'],['underline','下划线 ⌘U'],['strike','删除线']])button(text,name,label);
  const lists=group(main,'列表');for(const [name,label]of [['bulletList','无序列表'],['orderedList','有序列表'],['taskList','任务列表']])button(lists,name,label);
  const insert=group(main,'插入');button(insert,'link','插入或编辑链接 ⌘K');button(insert,'image','插入图片');
  select(insert,'表格操作',[['','表格'],['insertTable','插入 3 × 3 表格'],['addRowAfter','下方加行'],['addColumnAfter','右侧加列'],['deleteRow','删除行'],['deleteColumn','删除列'],['mergeCells','合并单元格'],['splitCell','拆分单元格'],['toggleHeaderRow','切换表头'],['deleteTable','删除表格']],(value,select)=>{const editor=getEditor();if(value==='insertTable')editor.chain().focus().insertTable({rows:3,cols:3,withHeaderRow:true}).run();else if(value)editor.chain().focus()[value]().run();select.value='';},'table');
  const history=group(main,'编辑历史');button(history,'undo','撤销 ⌘Z');button(history,'redo','重做 ⇧⌘Z');
  const more=document.createElement('button');more.type='button';more.id='more-format';more.className='toolbar-more';more.innerHTML=icon('more')+'<span>更多格式</span>';more.title='展开颜色、对齐、代码和其他格式';more.setAttribute('aria-label','更多格式');more.setAttribute('aria-controls',advanced.id);more.setAttribute('aria-expanded','false');main.append(more);
  const setExpanded=expanded=>{advanced.hidden=!expanded;more.setAttribute('aria-expanded',String(expanded));};
  more.onmousedown=event=>event.preventDefault();more.onclick=()=>setExpanded(advanced.hidden);
  container.addEventListener('keydown',event=>{if(event.key==='Escape'&&!advanced.hidden){event.preventDefault();setExpanded(false);more.focus({preventScroll:true});}});
  const extraText=group(advanced,'文字',true);for(const [name,label]of [['code','行内代码'],['subscript','下标'],['superscript','上标'],['clear','清除格式']])button(extraText,name,label);
  const colors=group(advanced,'颜色',true);
  for(const [name,label,value]of [['color','文字颜色','#7960b2'],['highlight','高亮颜色','#e8ddff']]){
    const choice=document.createElement('label');choice.className='toolbar-color';const caption=document.createElement('span');caption.textContent=name==='color'?'文字':'高亮';
    const input=document.createElement('input');input.type='color';input.value=value;input.title=label;input.setAttribute('aria-label',label);input.oninput=()=>{const editor=getEditor();if(editor)name==='color'?editor.chain().focus().setColor(input.value).run():editor.chain().focus().setHighlight({color:input.value}).run();};choice.append(caption,input);colors.append(choice);
  }
  const blocks=group(advanced,'段落',true);for(const [name,label]of [['blockquote','引用块'],['codeBlock','代码块'],['horizontalRule','分隔线']])button(blocks,name,label);
  select(blocks,'段落对齐',[['','对齐'],['left','左对齐'],['center','居中'],['right','右对齐'],['justify','两端对齐']],(value,select)=>{if(value)getEditor().chain().focus().setTextAlign(value).run();select.value='';});
  const code=group(advanced,'代码',true);
  const language=select(code,'代码语言',[['','代码语言'],...['plaintext','javascript','typescript','python','swift','json','bash','html','css','sql','java','cpp','go','rust','yaml','markdown'].map(x=>[x,x])],value=>{const editor=getEditor();if(editor.isActive('codeBlock'))editor.chain().focus().updateAttributes('codeBlock',{language:value || null}).run();});
  const media=group(advanced,'图片',true);button(media,'imageEdit','查看、替换、删除或设置替代文本');
  return {heading,language,closeAdvanced:()=>setExpanded(false)};
}
