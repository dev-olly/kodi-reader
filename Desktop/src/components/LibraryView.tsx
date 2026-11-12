import { useEffect, useMemo, useState } from 'react';
import { ArrowDownWideNarrow, BookOpen, FileText, Grid2X2, Link, List, MoreHorizontal, Plus, Search } from 'lucide-react';
import { isLibraryBook, matchingBooks, percent } from '../model';
import { mediaSource } from '../native';
import { readPreference, savePreference } from '../preferences';
import type { Book, Library } from '../types';
import { ActionMenu, EmptyState, IconButton, Spinner } from './Primitives';

export function BookCover({ book, small = false }: { book: Book; small?: boolean }) {
  const [src, setSrc] = useState<string | null>(null);
  useEffect(() => {
    let alive = true; setSrc(null);
    if (book.coverPath) mediaSource(book.coverPath).then(url => { if (alive) setSrc(url); }).catch(() => {});
    return () => { alive = false; };
  }, [book.coverPath]);
  return <div className={`book-cover${small ? ' small' : ''}`} data-tone={book.title.length % 5}>{src ? <img src={src} alt="" loading="lazy" /> : <><span className="cover-rule" /><span className="cover-title">{book.title}</span><span className="cover-author">{book.author || 'Kodi Reader'}</span><BookOpen aria-hidden="true" size={small ? 18 : 27} /></>}<span className="book-kind">{book.kind.toUpperCase()}</span></div>;
}
export function LibraryView({ library, loading, onOpen, onImport, onRename, onDelete, onAddURL }: {
  library: Library; loading: boolean; onOpen: (book: Book) => void; onImport: () => void;
  onRename: (book: Book) => void; onDelete: (book: Book) => void; onAddURL: () => void;
}) {
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState(() => readPreference('kodi-desktop.filter', ['all', 'recent', 'progress', 'unread', 'finished'], 'all'));
  const [sort, setSort] = useState(() => readPreference('kodi-desktop.sort', ['recent', 'added', 'title'], 'recent'));
  const [descending, setDescending] = useState(() => readPreference('kodi-desktop.descending', ['true', 'false'], sort === 'title' ? 'false' : 'true') === 'true');
  const [layout, setLayout] = useState(() => readPreference('kodi-desktop.layout', ['grid', 'list'], 'grid'));
  const documentCount = useMemo(() => Object.values(library.books).filter(isLibraryBook).length, [library.books]);
  const books = useMemo(() => matchingBooks(Object.values(library.books), query, filter, sort, descending), [library.books, query, filter, sort, descending]);
  useEffect(() => { savePreference('kodi-desktop.sort', sort); }, [sort]);
  useEffect(() => { savePreference('kodi-desktop.descending', String(descending)); }, [descending]);
  useEffect(() => { savePreference('kodi-desktop.layout', layout); }, [layout]);
  useEffect(() => { savePreference('kodi-desktop.filter', filter); }, [filter]);
  return <section className="library-view content-view">
    <header className="page-heading"><div><span className="eyebrow">YOUR READING SPACE</span><h1>Library</h1><p>{documentCount ? `${documentCount} documents · A little further, every day.` : 'A quiet place for your next good read.'}</p></div><div className="heading-actions"><button className="button subtle save-webpage-button" onClick={onAddURL} aria-label="Save a webpage" title="Save a webpage"><Link size={15} /><span>Save a webpage</span></button><button className="button primary" onClick={onImport}><Plus size={17} />Add books</button></div></header>
    <div className="library-tools"><div className="search-field"><Search size={16} /><input aria-label="Search library" placeholder="Search by title or author…" value={query} onChange={event => setQuery(event.target.value)} />{query ? <button onClick={() => setQuery('')} aria-label="Clear search">×</button> : null}</div><div className="tool-spacer" /><select className="compact-select" aria-label="Sort books" value={sort} onChange={event => { setSort(event.target.value); setDescending(event.target.value !== 'title'); }}><option value="recent">Last read</option><option value="added">Date added</option><option value="title">Title</option></select><IconButton label={descending ? 'Sort ascending' : 'Sort descending'} onClick={() => setDescending(!descending)}><ArrowDownWideNarrow size={17} /></IconButton><div className="segmented"><IconButton label="Grid view" active={layout === 'grid'} onClick={() => setLayout('grid')}><Grid2X2 size={16} /></IconButton><IconButton label="List view" active={layout === 'list'} onClick={() => setLayout('list')}><List size={18} /></IconButton></div></div>
    <div className="filter-tabs" role="group" aria-label="Filter library">{[['all', 'All books'], ['recent', 'Recently read'], ['progress', 'In progress'], ['unread', 'Unread'], ['finished', 'Finished']].map(([value, label]) => <button key={value} className={filter === value ? 'selected' : ''} aria-pressed={filter === value} onClick={() => setFilter(value)}>{label}</button>)}</div>
    {loading ? <div className="center-loading"><Spinner label="Opening your library…" /></div> : !books.length ? <EmptyState icon={<BookOpen size={32} />} title={query || filter !== 'all' ? 'No matching books' : 'Make room for a good book'} action={!query && filter === 'all' ? <button className="button primary" onClick={onImport}><Plus size={16} />Import EPUB or PDF</button> : <button className="button" onClick={() => { setQuery(''); setFilter('all'); }}>Show all books</button>}><p>{query || filter !== 'all' ? 'Try another search or reading filter.' : 'Add an EPUB or PDF to start reading, collecting ideas, and making notes. Your library stays on this device.'}</p></EmptyState> : <div className={layout === 'grid' ? 'book-grid' : 'book-list'}>{books.map(book => <article className="book-card" key={book.id}>
      <button className="book-open" onClick={() => onOpen(book)} aria-label={`Read ${book.title}`}><BookCover book={book} small={layout === 'list'} /><div className="book-info"><h3>{book.title}</h3><p>{book.author || 'Unknown author'}</p><div className="book-progress"><div className="progress-track"><i style={{ width: `${percent(book.progress)}%` }} /></div><span>{book.progress > 0 ? `${percent(book.progress)}%` : 'Unread'}</span></div></div></button>
      <ActionMenu className="book-menu" label={`Actions for ${book.title}`} trigger={<MoreHorizontal size={18} />}><button type="button" onClick={() => onRename(book)}>Rename…</button><button type="button" onClick={() => onOpen(book)}><BookOpen size={14} />Open document</button><button type="button" className="danger" onClick={() => onDelete(book)}>Remove from library…</button></ActionMenu>
    </article>)}</div>}
    <footer className="library-footer"><FileText size={13} /><span>EPUB & PDF · Offline reading · Your ideas, kept close</span></footer>
  </section>;
}
