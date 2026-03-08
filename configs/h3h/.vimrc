" Vincent Foley Bourgon's .vimrc (gnuvince@yahoo.ca)
" Last change: 2001/07/09
" Severely hacked up by Joe Auricchio
" Last change: 23 Oct 2005

" No compatible.  We want to use Vim, not vi
set nocp

" Give us all the good filetype stuff
filetype on
filetype indent on
filetype plugin on

" We don't wrap lines, they become a LONG horizontal one (useful)
" jra: yes we do. no they don't. no it isn't.
"set nowrap

" Stop the title change
set notitle

" We keep 4 lines when scrolling
set scrolloff=4

" We show vertical and horizontal position
set ruler

" Little hint of what command we're in the middle of
set showcmd

" This really should be default
set showmode

" Highlight searches
set hls

" ...but don't retain search highlighting across sessions
set viminfo+=h

" and SAVE ANYTHING I PUT INTO A BUFFER, GOD DAMMIT
set viminfo+=<100000000

" Y = y$ not yy by analogy with D = d$ and C = c$
noremap Y y$

" Tilde (~) acts like an operator (like 'd' or 'c')
set top

" Incremental search
set is

" Ignore case when searching
set ic

" Show matching ()'s []'s {}'s
set sm

" Tabs are 4 spaces long
set tabstop=4
" bjf: spaces are evil
"set expandtab

" When autoindent does a tab, it's 4 spaces long
set shiftwidth=4

" like :wq except write and suspend
command Wst w <bar> st
cabbrev wst Wst
cabbrev wz Wst
cabbrev Wq wq

" vfb: No need to save to make a :next :previous, etc.
" jra: I'd like to save changes only if I really want to., at least until I
"      have a real versioning filesystem
"set aw

" C-a and C-e go to beginning/end of line in insert mode (I hate Home and End)
" jra: I concur. And it's a big pain to type them on my laptop.
" NOTE: this will probably fail if you're using screen
inoremap <C-a> <Home>
inoremap <C-e> <End>

" vfb: I like using C-g a` la Emacs in the command line.  Don't ask me why.
" jra: I don't.
"cnoremap <C-g> <Esc>

" vfb: No idea what it's for...
" jra: It lets you backspace over everything, like modern editors and unlike vi
"      This is usually required to maintain sanity.
set backspace=2

" No annoying bell sound
set noerrorbells

" Put title in title bar
" jra: I'd like to suppress the "thanks for flying vim" though
" bjf: This was done with *notitle* at the top
" set title

" Smoother changes--we're not on a serial line these days
set ttyfast

" Tabs are converted to space characters...
" bjf: spaces are evil
"set et

" ...except in Makefiles
" bjf: unnecessary
"autocmd BufRead  [mM]akefile                    set noet
"autocmd BufNewFile [mM]akefile                  set noet


" Remove autocommands just in case
"autocmd!

" When using mutt or slrn, text width=72
"autocmd BufRead  mutt*[0-9]                    set tw=72
"autocmd BufRead  .followup,.article,.letter    set tw=72

" vfb: Text files have a text width of 72 characters
" jra: I don't understand the reasoning behind this, but I do understand that
"      it's a terrible waste of screen space. Instead I'll set it to 80 with
"      autowrap.
autocmd BufNewFile *.txt                       set tw=80
autocmd BufNewFile *.txt                       set wrap
autocmd BufRead    *.txt                       set tw=80
autocmd BufRead    *.txt                       set wrap

" vfb: LaTeX configuration is in ~/vim/vim.latex
" jra: No it's not.
"autocmd BufNewFile *.tex            source ~/vim/latex.vimrc
"autocmd BufRead    *.tex            source ~/vim/latex.vimrc

" Automatically chmod +x Shell and Perl scripts
" Another one of those things that keeps coders mentally stable.
autocmd BufWritePost   *.sh             !chmod +x %
autocmd BufWritePost   *.pl             !chmod +x %

" Jump back to the last place we were in a file
" jra: Whoever invented this is a flippin' genius. If I ever meet him/her I'll
"      take him/her out for sushi at the best place in town.
 autocmd BufReadPost *
\ if line("'\"") > 0 && line ("'\"") <= line("$") |
\   exe "normal g'\"" |
\ endif


"---- syntax highlighting, autoindents, other fun stuff ----

" We really want colors to be on. Really. I've more often found this to be
" necessary than redundant, and more often redundant than harmful.
if has("terminfo")
    set t_Co=8
    set t_Sf=[3%p1%dm
    set t_Sb=[4%p1%dm
else
    set t_Co=8
    set t_Sf=[3%dm
    set t_Sb=[4%dm
endif

" We put syntax highlighting (COLORS!!)
syntax on

" Set background to dark to have nicer syntax highlighting.
set background=dark

" Turn on autoindent
set ai

" Turn on smarter autoindents for C code
set cin

" Automatically insert comment leaders in carriage returns...
" and break comments at textwidth
set formatoptions+=roc

" ...but not // comments (this is just a personal style thing)
set comments-=://


" eruby syntax for .rhtml!
" au BufNewFile,BufRead *.rhtml set syn=eruby

" Cooler indentation + folds
" au BufNewFile,BufRead *.rb set sw=2 ts=2 foldmethod=marker



"---- abbreviations and such ----
" (see also the Great Virtues of Programmers)

ab #d #define
ab #i #include

