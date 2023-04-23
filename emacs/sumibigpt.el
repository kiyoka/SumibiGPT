;;; sumibigpt.el --- Japanese input method using OpenAI GPT.
;;
;; Copyright (C) 2023 Kiyoka Nishiyama
;;
;; Author: Kiyoka Nishiyama <kiyoka@sumibi.org>
;; Version: 1.0.0          ;;SUMIBIGPT-VERSION
;; Keywords: ime, japanese
;; Package-Requires: ((cl-lib "1.0") (popup "0.5.9") (unicode-escapeo "20230109.1222"))
;; URL: https://github.com/kiyoka/SumibiGPT
;;
;; This file is part of SumibiGPT
;; This program was derived from sumibi.el and sekka.el and yc.el-4.0.13(auther: knak)
;;
;; SumibiGPT is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;;
;; SumibiGPT is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with SumibiGPT; see the file COPYING.
;;

;;; Commentary:

;; you might want to enable IME:
;;
;;  (require 'sumibigpt)
;;  (global-sumibigpt-mode 1)
;;
;;

;;; Code:
(require 'cl)
(require 'popup)
(require 'url-parse)
(require 'unicode-escape)

;;; 
;;;
;;; customize variables
;;;
(defgroup sumibigpt nil
  "SumibiGPT client."
  :group 'input-method
  :group 'Japanese)

(defcustom sumibigpt-stop-chars "(){}<>"
  "*漢字変換文字列を取り込む時に変換範囲に含めない文字を設定する"
  :type  'string
  :group 'sumibigpt)

(defcustom sumibigpt-current-model "gpt-3.5-turbo"
  "OpenAPIのLLM使用モデル名を指定する"
  :type  'string
  :group 'sumibigpt)

(defcustom sumibigpt-history-stack-limit 100
  "再度候補選択できる単語と場所を最大何件記憶するか"
  :type  'integer
  :group 'sumibigpt)

(defvar sumibigpt-mode nil             "漢字変換トグル変数")
(defun sumibigpt-modeline-string ()
  ;; 接続先sumibigpt-serverのホスト名を表示する。
  (format " SumibiGPT[%s]" sumibigpt-current-model))

(defvar sumibigpt-select-mode nil      "候補選択モード変数")
(or (assq 'sumibigpt-mode minor-mode-alist)
    (setq minor-mode-alist (cons
			    '(sumibigpt-mode (:eval (sumibigpt-modeline-string)))
			    minor-mode-alist)))


;; ローマ字漢字変換時、対象とするローマ字を設定するための変数
(defvar sumibigpt-skip-chars "a-zA-Z0-9.,@:`\\-+!\\[\\]?;' ")
(defvar sumibigpt-mode-map        (make-sparse-keymap)         "漢字変換トグルマップ")
(defvar sumibigpt-select-mode-map (make-sparse-keymap)         "候補選択モードマップ")
(defvar sumibigpt-rK-trans-key "\C-j"
  "*漢字変換キーを設定する")
(or (assq 'sumibigpt-mode minor-mode-map-alist)
    (setq minor-mode-map-alist
	  (append (list (cons 'sumibigpt-mode         sumibigpt-mode-map)
			(cons 'sumibigpt-select-mode  sumibigpt-select-mode-map))
		  minor-mode-map-alist)))


;;;
;;; hooks
;;;
(defvar sumibigpt-mode-hook nil)
(defvar sumibigpt-select-mode-hook nil)
(defvar sumibigpt-select-mode-end-hook nil)

(defconst sumibigpt-tango-index  0)
(defconst sumibigpt-annotation-index  1)
(defconst sumibigpt-kind-index   3)
(defconst sumibigpt-id-index     4)

;;--- デバッグメッセージ出力
(defvar sumibigpt-psudo-server nil)         ; クライアント単体で仮想的にサーバーに接続しているようにしてテストするモード

;;--- デバッグメッセージ出力
(defvar sumibigpt-debug nil)		; デバッグフラグ
(defun sumibigpt-debug-print (string)
  (if sumibigpt-debug
      (let
	  ((buffer (get-buffer-create "*sumibigpt-debug*")))
	(with-current-buffer buffer
	  (goto-char (point-max))
	  (insert string)))))

;; HTTPクライアントの多重起動防止用
(defvar sumibigpt-busy 0)


;;; 候補選択モード用
(defvar sumibigpt-history-stack '())        ; 過去に変換した、場所と変換候補の状態を保存しておくスタック
;; データ構造は以下の通り。
;; alistのlistとなる。 alistのキーは、sumibigpt-* というバッファローカル変数のバックアップとなる)
;; 新しいものは先頭に追加され、検索も先頭から行われる。即ち、古い情報も残るがいつかstackのlimitを超えるとあふれて捨てられる。
;;(
;; (
;;  (bufname           . "*scratch*")
;;  (markers           . '(#<marker at 192 in *scratch*> . #<marker at 194 in *scratch*>))
;;  (cand-cur          . 0)
;;  (cand-cur-backup   . 0)
;;  (cand-len          . 0)
;;  (last-fix          . 0)
;;  (henkan-kouho-list . '())
;;  ))
(defvar sumibigpt-fence-start nil)          ; fence 始端marker
(defvar sumibigpt-fence-end nil)            ; fence 終端marker
(defvar sumibigpt-henkan-separeter " ")     ; fence mode separeter
(defvar sumibigpt-cand-cur 0)               ; カレント候補番号
(defvar sumibigpt-cand-cur-backup 0)        ; カレント候補番号(UNDO用に退避する変数)
(defvar sumibigpt-cand-len nil)             ; 候補数
(defvar sumibigpt-last-fix "")              ; 最後に確定した文字列
(defvar sumibigpt-last-roman "")            ; 最後にsumibigpt-serverにリクエストしたローマ字文字列
(defvar sumibigpt-select-operation-times 0) ; 選択操作回数
(defvar sumibigpt-henkan-kouho-list nil)    ; 変換結果リスト(サーバから帰ってきたデータそのもの)


;; その他
(defvar sumibigpt-markers '())              ; 単語の開始、終了位置のpair。 次のような形式で保存する ( 1 . 2 )
(defvar sumibigpt-timer    nil)             ; インターバルタイマー型変数
(defvar sumibigpt-timer-rest  0)            ; あと何回呼出されたら、インターバルタイマの呼出を止めるか
(defvar sumibigpt-last-lineno 0)            ; 最後に変換を実行した行番号
(defvar sumibigpt-guide-overlay   nil)      ; リアルタイムガイドに使用するオーバーレイ
(defvar sumibigpt-last-request-time 0)      ; OpenAIサーバーにリクエストした最後の時刻(単位は秒)
(defvar sumibigpt-guide-lastquery  "")      ; OpenAIサーバーにリクエストした最後のクエリ文字列
(defvar sumibigpt-guide-lastresult '())     ; OpenAIサーバーにリクエストした最後のクエリ結果



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; ユーティリティ
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun sumibigpt-assoc-ref (key alist fallback)
  (let ((entry (assoc key alist)))
    (if entry
	(cdr entry)
      fallback)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; 表示系関数群
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defvar sumibigpt-use-fence t)
(defvar sumibigpt-use-color nil)
(defvar sumibigpt-init nil)

;;
;; 初期化
;;
(defun sumibigpt-init ()
  (when (not sumibigpt-init)
    ;; 初期化完了
    (setq sumibigpt-init t)))


;;
;; OpenAPIにプロンプトを発行する
;;
(defun openai-http-post (system-content1
			 user-content1
			 assistant-content1
			 user-content2
			 arg-n)
  "call OpenAI completions API."
  (progn
    (setq url "https://api.openai.com/v1/chat/completions")
    (setq url-request-method "POST")
    (setq url-http-version "1.1")
    (setq url-request-extra-headers
	  `(("Content-Type" . "application/json; charset=utf-8")
	    ("Authorization" . ,(concat "Bearer " (getenv "OPENAI_API_KEY")))))
    (setq url-request-data
	  (concat
	   "{"
	   (format "  \"model\": \"%s\"," sumibigpt-current-model)
	   "  \"temperature\": 0.8,"
	   (format  "  \"n\": %d," arg-n)
	   "  \"messages\": [ "
	   (format " {\"role\": \"system\",    \"content\": \"%s\"}," (unicode-escape system-content1))
	   (format " {\"role\": \"user\",      \"content\": \"%s\"}," (unicode-escape user-content1))
	   (format " {\"role\": \"assistant\", \"content\": \"%s\"}," (unicode-escape assistant-content1))
	   (format " {\"role\": \"user\",      \"content\": \"%s\"} " (unicode-escape user-content2))
	   "  ] "
	   "}"))
    (sumibigpt-debug-print (format "user-content2 [%s]" user-content2))
    (let* ((lines
	    (let ((buf (url-retrieve-synchronously url)))
	      (sumibigpt-debug-print (buffer-name buf))
	      (sumibigpt-debug-print "\n")
	      (if buf
                  (with-current-buffer buf
                    (decode-coding-string 
                     (let ((str (buffer-substring-no-properties (point-min) (point-max))))
                       (cond
                        (url-http-response-status
                         (sumibigpt-debug-print (format "http result code:%s\n" url-http-response-status))
                         (sumibigpt-debug-print (format "(%d-%d) eoh=%s\n" (point-min) (point-max) url-http-end-of-headers))
                         (sumibigpt-debug-print (format "<<<%s>>>\n" str))
                         str)
                        (t
                         "<<TIMEOUT>>\n"
                         )))
                     'utf-8))
                "<<CONNECTION ERROR>>\n")))
           (line-list
            (split-string lines "\n")))
      (cadr (reverse line-list)))))

;;
;; ローマ字で書かれた文章をOpenAIサーバーを使って変換し、結果を文字列で返す。
;; roman: "bunsyou no mojiretu"
;; arg-n: 候補を何件返すか
;; return: (("文章の文字列" "候補N" 0 j index) ...)
;;
(defun sumibigpt-roman-to-kanji (roman arg-n)
  (let* ((json-str (openai-http-post
		    "あなたはローマ字を日本語に変換するアシスタントです。"
		    "ローマ字の文を漢字仮名混じり文にしてください。 : watashi no namae ha nakano desu ."
		    "私の名前は中野です。"
		    (format "ローマ字の文を漢字仮名混じり文にしてください。 : %s" roman)
		    arg-n))
	 (json-obj (json-parse-string json-str))
	 (result '())
	 (count 0))
    (while (< count arg-n)
      (let* ((hex-str
	      (gethash "content"
		       (gethash "message"
				(aref (gethash "choices" json-obj) count))))
	     (utf8-str
	      (decode-coding-string (url-unhex-string hex-str) 'utf-8)))
	(setq result (append result
			     (list (list
				    utf8-str
				    (format "候補%d" (+ count 1))
				    0
				    'j
				    count)))))
      (setq count (1+ count)))
    result))

;;
;; ローマ字で書かれた文章を複数候補作成して返す
;;
(defun sumibigpt-henkan-request (roman)
  (append
   (sumibigpt-roman-to-kanji roman 3)
   ;;原文のまま
   (list (list roman "原文まま" 0 'l 3))))

(when nil
;; unit test
  (sumibigpt-henkan-request "watashi no namae ha nakano desu ."))


(defun sumibigpt-file-existp (file)
  "FILE が存在するかどうかをチェックする。 t か nil で結果を返す"
  (let* ((file (or (car-safe file)
		   file))
	 (file (expand-file-name file)))
    (file-exists-p file)))


;; リージョンをローマ字漢字変換する関数
(defun sumibigpt-henkan-region (b e)
  "指定された region を漢字変換する"
  (sumibigpt-init)
  (when (/= b e)
    (let* (
	   (yomi (buffer-substring-no-properties b e))
	   (henkan-list (sumibigpt-henkan-request yomi)))
      
      (if henkan-list
	  (condition-case err
	      (progn
		(setq
		 ;; 変換結果の保持
		 sumibigpt-henkan-kouho-list henkan-list
		 ;; 文節選択初期化
		 sumibigpt-cand-cur 0
		 ;; 
		 sumibigpt-cand-len (length henkan-list))
		
		(sumibigpt-debug-print (format "sumibigpt-henkan-kouho-list:%s \n" sumibigpt-henkan-kouho-list))
		(sumibigpt-debug-print (format "sumibigpt-cand-cur:%s \n" sumibigpt-cand-cur))
		(sumibigpt-debug-print (format "sumibigpt-cand-len:%s \n" sumibigpt-cand-len))
		;;
		t)
	    (sumibigpt-trap-server-down
	     (beep)
	     (message (error-message-string err))
	     (setq sumibigpt-select-mode nil))
	    (run-hooks 'sumibigpt-select-mode-end-hook))
	nil))))


;; カーソル前の文字種を返却する関数
(defun sumibigpt-char-charset (ch)
  (let ((result (char-charset ch)))
    (sumibigpt-debug-print (format "sumibigpt-char-charset:1(%s) => %s\n" ch result))
    (if (multibyte-string-p (char-to-string ch)) 
	'japanese-jisx0208
      result)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; undo 情報の制御
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; undo buffer 退避用変数
(defvar sumibigpt-buffer-undo-list nil)
(make-variable-buffer-local 'sumibigpt-buffer-undo-list)
(defvar sumibigpt-buffer-modified-p nil)
(make-variable-buffer-local 'sumibigpt-buffer-modified-p)

(defvar sumibigpt-blink-cursor nil)
(defvar sumibigpt-cursor-type nil)
;; undo buffer を退避し、undo 情報の蓄積を停止する関数
(defun sumibigpt-disable-undo ()
  (when (not (eq buffer-undo-list t))
    (setq sumibigpt-buffer-undo-list buffer-undo-list)
    (setq sumibigpt-buffer-modified-p (buffer-modified-p))
    (setq buffer-undo-list t)))

;; 退避した undo buffer を復帰し、undo 情報の蓄積を再開する関数
(defun sumibigpt-enable-undo ()
  (when (not sumibigpt-buffer-modified-p) (set-buffer-modified-p nil))
  (when sumibigpt-buffer-undo-list
    (setq buffer-undo-list sumibigpt-buffer-undo-list)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; 現在の変換エリアの表示を行う
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun sumibigpt-get-display-string ()
  ;; 変換結果文字列を返す。
  (let* ((kouho      (nth sumibigpt-cand-cur sumibigpt-henkan-kouho-list))
	 (_          (sumibigpt-debug-print (format "sumibigpt-cand-cur=%s\n" sumibigpt-cand-cur)))
	 (_          (sumibigpt-debug-print (format "kouho=%s\n" kouho)))
	 (word       (car kouho))
	 (annotation (cadr kouho)))
    (sumibigpt-debug-print (format "word:[%d] %s(%s)\n" sumibigpt-cand-cur word annotation))
    word))

(defun sumibigpt-display-function (b e select-mode)
  (let ((insert-word (sumibigpt-get-display-string))
	(word (buffer-substring-no-properties b e)))
    (cond
     ((and (not select-mode)
	   (string-equal insert-word word))
      ;; sumibigpt-markersの更新
      (setq sumibigpt-fence-start (progn
				(goto-char b)
				(point-marker)))
      (setq sumibigpt-fence-end   (progn
				(goto-char e)
				(point-marker)))
      (setq sumibigpt-markers
	    (cons sumibigpt-fence-start sumibigpt-fence-end))

      ;; 確定文字列の作成
      (setq sumibigpt-last-fix insert-word)
      
      (sumibigpt-debug-print (format "don't touch:[%s] point:%d-%d\n" insert-word (marker-position sumibigpt-fence-start) (marker-position sumibigpt-fence-end))))

     (t
      (setq sumibigpt-henkan-separeter (if sumibigpt-use-fence " " ""))
      (when sumibigpt-henkan-kouho-list
	;; UNDO抑制開始
	(sumibigpt-disable-undo)
	
	(delete-region b e)

	;; リスト初期化
	(setq sumibigpt-markers '())

	(setq sumibigpt-last-fix "")

	;; 変換したpointの保持
	(setq sumibigpt-fence-start (point-marker))
	(when select-mode (insert "|"))
    
	(let* (
	       (start       (point-marker))
	       (_cur        sumibigpt-cand-cur)
	       (_len        sumibigpt-cand-len))
	  (progn
	    (insert insert-word)
	    (message (format "[%s] candidate (%d/%d)" insert-word (+ _cur 1) _len))
	    (let* ((end         (point-marker))
		   (ov          (make-overlay start end)))
	      
	      ;; 確定文字列の作成
	      (setq sumibigpt-last-fix insert-word)
	      
	      ;; 選択中の場所を装飾する。
	      (when select-mode
		(overlay-put ov 'face 'default)
		(overlay-put ov 'face 'highlight))
	      (setq sumibigpt-markers (cons start end))
	      (sumibigpt-debug-print (format "insert:[%s] point:%d-%d\n" insert-word (marker-position start) (marker-position end))))))
	
	;; fenceの範囲を設定する
	(when select-mode (insert "|"))
	(setq sumibigpt-fence-end   (point-marker))
	
	(sumibigpt-debug-print (format "total-point:%d-%d\n"
				   (marker-position sumibigpt-fence-start)
				   (marker-position sumibigpt-fence-end)))
	;; UNDO再開
	(sumibigpt-enable-undo))))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; 変換候補選択モード
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(let ((i 0))
  (while (<= i ?\177)
    (define-key sumibigpt-select-mode-map (char-to-string i)
      'sumibigpt-kakutei-and-self-insert)
    (setq i (1+ i))))
(define-key sumibigpt-select-mode-map "\C-m"                   'sumibigpt-select-kakutei)
(define-key sumibigpt-select-mode-map "\C-g"                   'sumibigpt-select-cancel)
(define-key sumibigpt-select-mode-map "q"                      'sumibigpt-select-cancel)
(define-key sumibigpt-select-mode-map "\C-a"                   'sumibigpt-select-kanji)
(define-key sumibigpt-select-mode-map "\C-p"                   'sumibigpt-select-prev)
(define-key sumibigpt-select-mode-map "\C-n"                   'sumibigpt-select-next)
(define-key sumibigpt-select-mode-map sumibigpt-rK-trans-key       'sumibigpt-select-next)
(define-key sumibigpt-select-mode-map (kbd "SPC")              'sumibigpt-select-next)
(define-key sumibigpt-select-mode-map "\C-u"                   'sumibigpt-select-hiragana)
(define-key sumibigpt-select-mode-map "\C-i"                   'sumibigpt-select-katakana)
(define-key sumibigpt-select-mode-map "\C-k"                   'sumibigpt-select-katakana)
(define-key sumibigpt-select-mode-map "\C-l"                   'sumibigpt-select-hankaku)
(define-key sumibigpt-select-mode-map "\C-e"                   'sumibigpt-select-zenkaku)
(define-key sumibigpt-select-mode-map "\C-r"                   'sumibigpt-add-new-word)


(defvar sumibigpt-popup-menu-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map "\r"        'popup-select)
    (define-key map "\C-f"      'popup-open)
    (define-key map [right]     'popup-open)
    (define-key map "\C-b"      'popup-close)
    (define-key map [left]      'popup-close)

    (define-key map "\C-n"      'popup-next)
    (define-key map "\C-j"      'popup-next)
    (define-key map (kbd "SPC") 'popup-next)
    (define-key map [down]      'popup-next)
    (define-key map "\C-p"      'popup-previous)
    (define-key map [up]        'popup-previous)

    (define-key map [f1]        'popup-help)
    (define-key map (kbd "\C-?") 'popup-help)

    (define-key map "\C-s"      'popup-isearch)
    (define-key map "\C-g"      'popup-close)
    (define-key map "\C-r"      'popup-select)
    map))


;; 選択操作回数のインクリメント
(defun sumibigpt-select-operation-inc ()
  (incf sumibigpt-select-operation-times)
  (when (< 3 sumibigpt-select-operation-times)
    (sumibigpt-select-operation-reset)
    (let* ((lst 
	    (mapcar
	     (lambda (x)
	       (concat 
		(nth sumibigpt-tango-index x)
		"   ; "
		(nth sumibigpt-annotation-index x)))
	     sumibigpt-henkan-kouho-list))
	   (map (make-sparse-keymap))
	   (result 
	    (popup-menu* lst
			 :scroll-bar t
			 :margin t
			 :keymap sumibigpt-popup-menu-keymap
                         :initial-index sumibigpt-cand-cur)))
      (let ((selected-word (car (split-string result " "))))
	(setq sumibigpt-cand-cur (sumibigpt-find-by-tango selected-word))))))


;; 選択操作回数のリセット
(defun sumibigpt-select-operation-reset ()
  (setq sumibigpt-select-operation-times 0))

;; 変換を確定し入力されたキーを再入力する関数
(defun sumibigpt-kakutei-and-self-insert (arg)
  "候補選択を確定し、入力された文字を入力する"
  (interactive "P")
  (sumibigpt-select-kakutei)
  (setq unread-command-events (list last-command-event)))

;; 候補選択状態での表示更新
(defun sumibigpt-select-update-display ()
  (sumibigpt-display-function
   (marker-position sumibigpt-fence-start)
   (marker-position sumibigpt-fence-end)
   sumibigpt-select-mode))


;; 候補選択を確定する
(defun sumibigpt-select-kakutei ()
  "候補選択を確定する"
  (interactive)
  ;; 候補番号リストをバックアップする。
  (setq sumibigpt-cand-cur-backup sumibigpt-cand-cur)
  (setq sumibigpt-select-mode nil)
  (run-hooks 'sumibigpt-select-mode-end-hook)
  (sumibigpt-select-operation-reset)
  (sumibigpt-select-update-display)
  (sumibigpt-history-push))


;; 候補選択をキャンセルする
(defun sumibigpt-select-cancel ()
  "候補選択をキャンセルする"
  (interactive)
  ;; カレント候補番号をバックアップしていた候補番号で復元する。
  (setq sumibigpt-cand-cur sumibigpt-cand-cur-backup)
  (setq sumibigpt-select-mode nil)
  (run-hooks 'sumibigpt-select-mode-end-hook)
  (sumibigpt-select-update-display)
  (sumibigpt-history-push))


;; 前の候補に進める
(defun sumibigpt-select-prev ()
  "前の候補に進める"
  (interactive)
  ;; 前の候補に切りかえる
  (decf sumibigpt-cand-cur)
  (when (> 0 sumibigpt-cand-cur)
    (setq sumibigpt-cand-cur (- sumibigpt-cand-len 1)))
  (sumibigpt-select-operation-inc)
  (sumibigpt-select-update-display))

;; 次の候補に進める
(defun sumibigpt-select-next ()
  "次の候補に進める"
  (interactive)
  ;; 次の候補に切りかえる
  (setq sumibigpt-cand-cur
	(if (< sumibigpt-cand-cur (- sumibigpt-cand-len 1))
	    (+ sumibigpt-cand-cur 1)
	  0))
  (sumibigpt-select-operation-inc)
  (sumibigpt-select-update-display))

;; 指定された tango のindex番号を返す
(defun sumibigpt-find-by-tango ( tango )
  (let ((result-index nil))
    (mapcar
     (lambda (x)
       (let ((_tango (nth sumibigpt-tango-index x)))
	 (when (string-equal _tango tango)
	   (setq result-index (nth sumibigpt-id-index x)))))
     sumibigpt-henkan-kouho-list)
    (sumibigpt-debug-print (format "sumibigpt-find-by-tango: tango=%s result=%S \n" tango result-index))
    result-index))

;; 指定された type の候補を抜き出す
(defun sumibigpt-select-by-type-filter ( _type )
  (let ((lst '()))
    (mapcar
     (lambda (x)
       (let ((sym (nth sumibigpt-kind-index x)))
	 (when (eq sym _type)
	   (push x lst))))
     sumibigpt-henkan-kouho-list)
    (sumibigpt-debug-print (format "filtered-lst = %S\n" (reverse lst)))
    (if (null lst)
	nil
      (reverse lst))))
  
    
;; 指定された type の候補が存在するか調べる
(defun sumibigpt-include-typep ( _type )
  (sumibigpt-select-by-type-filter _type))

;; 指定された type の候補に強制的に切りかえる
;; 切りかえが成功したかどうかを t or nil で返す。
(defun sumibigpt-select-by-type ( _type )
  (let ((kouho (car (sumibigpt-select-by-type-filter _type))))
    (if (not kouho)
	(progn
	 (cond
	  ((eq _type 'j)
	   (message "SumibiGPT: 漢字の候補はありません。"))
	  ((eq _type 'h)
	   (message "SumibiGPT: ひらがなの候補はありません。"))
	  ((eq _type 'k)
	   (message "SumibiGPT: カタカナの候補はありません。"))
	  ((eq _type 'l)
	   (message "SumibiGPT: 半角の候補はありません。"))
	  ((eq _type 'z)
	   (message "SumibiGPT: 全角の候補はありません。"))
	  ((eq _type 'n)
	   (message "SumibiGPT: 数字混在の候補はありません．")))
	 nil)
      (let ((num   (nth sumibigpt-id-index kouho)))
	(setq sumibigpt-cand-cur num)
	(sumibigpt-select-update-display)
	t))))

(defun sumibigpt-select-kanji ()
  "漢字候補に強制的に切りかえる"
  (interactive)
  (sumibigpt-select-by-type 'j))

(defun sumibigpt-select-hiragana ()
  "ひらがな候補に強制的に切りかえる"
  (interactive)
  (sumibigpt-select-by-type 'h))

(defun sumibigpt-select-katakana ()
  "カタカナ候補に強制的に切りかえる"
  (interactive)
  (sumibigpt-select-by-type 'k))

(defun sumibigpt-select-hankaku ()
  "半角候補に強制的に切りかえる"
  (interactive)
  (sumibigpt-select-by-type 'l))

(defun sumibigpt-select-zenkaku ()
  "半角候補に強制的に切りかえる"
  (interactive)
  (sumibigpt-select-by-type 'z))


(defun sumibigpt-replace-kakutei-word (b e insert-word)
  ;; UNDO抑制開始
  (sumibigpt-disable-undo)
    
  (delete-region b e)
  
  (insert insert-word)
  (message (format "replaced by new word [%s]" insert-word))
  ;; UNDO再開
  (sumibigpt-enable-undo))


(defun sumibigpt-add-new-word ()
  "変換候補のよみ(平仮名)に対応する新しい単語を追加する"
  (interactive)
  (setq case-fold-search nil)
  (let ((type
	 (cond
	  ((string-match-p "^[A-Z][^A-Z]+$" sumibigpt-last-roman)
	   (if (sumibigpt-select-by-type 'h) ;; 平仮名候補に自動切り替え
	       'H
	     nil))
	  ((string-match-p "^[a-z][^A-Z]+$" sumibigpt-last-roman)
	   'h)
	  (t
	   nil))))
    (let* ((kouho      (nth sumibigpt-cand-cur sumibigpt-henkan-kouho-list))
	   (hiragana   (car kouho)))
      (sumibigpt-debug-print (format "sumibigpt-register-new-word: sumibigpt-last-roman=[%s] hiragana=%s result=%S\n" sumibigpt-last-roman hiragana (string-match-p "^[A-Z][^A-Z]+$" sumibigpt-last-roman)))
      (cond
       ;; 漢字語彙をgoogleimeで取得
       ((eq 'H type)
	(sumibigpt-select-kakutei)
	(sumibigpt-add-new-word-sub
	 hiragana
	 (sumibigpt-googleime-request hiragana)
	 '()))
       ;; 平仮名フレーズから選択
       ((eq 'h type)
	(sumibigpt-select-kakutei)
	(let ((kouho (sumibigpt-select-by-type-filter 'h)))
	  (sumibigpt-debug-print (format "sumibigpt-register-new-word: kouho=%S\n" kouho))
	  (sumibigpt-add-new-word-sub
	   hiragana
	   '()
	   (cons
	    hiragana ;; 確定値の平仮名文言を先頭に追加。
	    (mapcar
	     (lambda (x) (car x)) kouho))))))
      )))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; 変換履歴操作関数
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun sumibigpt-history-gc ()
  ;; sumibigpt-history-stack中の無効なマークを持つエントリを削除する
  (sumibigpt-debug-print (format "sumibigpt-history-gc before len=%d\n" (length sumibigpt-history-stack)))

  (let ((temp-list '()))
    (mapcar
     (lambda (alist)
       (let ((markers  (sumibigpt-assoc-ref 'markers  alist nil)))
	 (sumibigpt-debug-print (format "markers=%S\n" markers))
	 (sumibigpt-debug-print (format "marker-position car=%S\n" (marker-position (car markers))))
	 (sumibigpt-debug-print (format "marker-position cdr=%S\n" (marker-position (cdr markers))))
	 (when (and (marker-position (car markers))	 ;; 存在するバッファを指しているか
		    (marker-position (cdr markers)))
	   (if (= (marker-position (car markers))
		  (marker-position (cdr markers)))
	       ;; マークの開始と終了が同じ位置を指している場合は、
	       ;; そのマークは既に無効(選択モードの再表示で一旦マーク周辺の文字列が削除された)
	       (progn
		 (set-marker (car markers) nil)
		 (set-marker (cdr markers) nil))
	     (push alist temp-list)))))
     sumibigpt-history-stack)

    (sumibigpt-debug-print (format "sumibigpt-history-gc temp-list  len=%d\n" (length temp-list)))

    ;; temp-list から limit 件数だけコピーする
    (setq sumibigpt-history-stack '())
    (mapcar
     (lambda (alist)
       (when (< (length sumibigpt-history-stack)
		sumibigpt-history-stack-limit)
	 (push alist sumibigpt-history-stack)))
     (reverse temp-list)))
  (sumibigpt-debug-print (format "sumibigpt-history-gc after  len=%d\n" (length sumibigpt-history-stack))))


;;確定ヒストリから、指定_pointに変換済の単語が埋まっているかどうか調べる
;; t か nil を返す。
;; また、_load に 真を渡すと、見付かった情報で、現在の変換候補変数にロードしてくれる。
(defun sumibigpt-history-search (_point _load)
  (sumibigpt-history-gc)

  ;; カーソル位置に有効な変換済エントリがあるか探す
  (let ((found nil))
    (mapcar
     (lambda (alist)
       (let* ((markers  (sumibigpt-assoc-ref 'markers  alist nil))
	      (last-fix (sumibigpt-assoc-ref 'last-fix alist ""))
	      (end      (marker-position (cdr markers)))
	      (start    (- end (length last-fix)))
	      (bufname  (sumibigpt-assoc-ref 'bufname alist ""))
	      (pickup   (if (string-equal bufname (buffer-name))
			    (buffer-substring start end)
			  "")))
	 (sumibigpt-debug-print (format "sumibigpt-history-search  bufname:   [%s]\n"   bufname))
	 (sumibigpt-debug-print (format "sumibigpt-history-search  (point):   %d\n"     (point)))
	 (sumibigpt-debug-print (format "sumibigpt-history-search    range:   %d-%d\n"  start end))
	 (sumibigpt-debug-print (format "sumibigpt-history-search last-fix:   [%s]\n"   last-fix))
	 (sumibigpt-debug-print (format "sumibigpt-history-search   pickup:   [%s]\n"   pickup))
	 (when (and
		(string-equal bufname (buffer-name))
		(<  start   (point))
		(<= (point) end)
		(string-equal last-fix pickup))
	   (setq found t)
	   (when _load
	     (setq sumibigpt-markers            (cons
					     (move-marker (car markers) start)
					     (cdr markers)))
	     (setq sumibigpt-cand-cur           (sumibigpt-assoc-ref 'cand-cur alist           nil))
	     (setq sumibigpt-cand-cur-backup    (sumibigpt-assoc-ref 'cand-cur-backup alist    nil))
	     (setq sumibigpt-cand-len           (sumibigpt-assoc-ref 'cand-len alist           nil))
	     (setq sumibigpt-last-fix           pickup)
	     (setq sumibigpt-henkan-kouho-list  (sumibigpt-assoc-ref 'henkan-kouho-list alist  nil))

	     (sumibigpt-debug-print (format "sumibigpt-history-search : sumibigpt-markers         : %S\n" sumibigpt-markers))
	     (sumibigpt-debug-print (format "sumibigpt-history-search : sumibigpt-cand-cur        : %S\n" sumibigpt-cand-cur))
	     (sumibigpt-debug-print (format "sumibigpt-history-search : sumibigpt-cand-cur-backup : %S\n" sumibigpt-cand-cur-backup))
	     (sumibigpt-debug-print (format "sumibigpt-history-search : sumibigpt-cand-len %S\n" sumibigpt-cand-len))
	     (sumibigpt-debug-print (format "sumibigpt-history-search : sumibigpt-last-fix %S\n" sumibigpt-last-fix))
	     (sumibigpt-debug-print (format "sumibigpt-history-search : sumibigpt-henkan-kouho-list %S\n" sumibigpt-henkan-kouho-list)))
	   )))
     sumibigpt-history-stack)
    found))

(defun sumibigpt-history-push ()
  (push 
   `(
     (markers            . ,sumibigpt-markers            )
     (cand-cur           . ,sumibigpt-cand-cur           )
     (cand-cur-backup    . ,sumibigpt-cand-cur-backup    )
     (cand-len           . ,sumibigpt-cand-len           )
     (last-fix           . ,sumibigpt-last-fix           )
     (henkan-kouho-list  . ,sumibigpt-henkan-kouho-list  )
     (bufname            . ,(buffer-name)))
   sumibigpt-history-stack)
  (sumibigpt-debug-print (format "sumibigpt-history-push result: %S\n" sumibigpt-history-stack)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; ローマ字漢字変換関数
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun sumibigpt-rK-trans ()
  "ローマ字漢字変換をする。
・カーソルから行頭方向にローマ字列が続く範囲でローマ字漢字変換を行う。"
  (interactive)
  (sumibigpt-debug-print "sumibigpt-rK-trans()")

  ;; 最後に変換した行番号の更新
  (setq sumibigpt-last-lineno (line-number-at-pos (point)))

  (cond
   (sumibigpt-select-mode
    (sumibigpt-debug-print "<<sumibigpt-select-mode>>\n")
    ;; 候補選択モード中に呼出されたら、keymapから再度候補選択モードに入る
    (funcall (lookup-key sumibigpt-select-mode-map sumibigpt-rK-trans-key)))

   (t
    (cond

     ((eq (sumibigpt-char-charset (preceding-char)) 'ascii)
      (sumibigpt-debug-print (format "ascii? (%s) => t\n" (preceding-char)))
      ;; カーソル直前が alphabet だったら
      (let ((end (point))
	    (gap (sumibigpt-skip-chars-backward)))
	(when (/= gap 0)
	  ;; 意味のある入力が見つかったので変換する
	  (let (
		(b (+ end gap))
		(e end))
	    (when (sumibigpt-henkan-region b e)
	      (if (eq (char-before b) ?/)
		  (setq b (- b 1)))
	      (setq sumibigpt-last-roman (buffer-substring-no-properties b e))
	      (delete-region b e)
	      (goto-char b)
	      (insert (sumibigpt-get-display-string))
	      (setq e (point))
	      (sumibigpt-display-function b e nil)
	      (sumibigpt-select-kakutei)
	      (cond
	       ((string-match-p "^[A-Z][^A-Z]+$" sumibigpt-last-roman)
		;; 漢字語彙
		(when sumibigpt-use-googleime
		  (if (not (sumibigpt-include-typep 'j))
		      (sumibigpt-add-new-word))))
	       (t
		;; 平仮名フレーズはGoogleIMEの問い合わせの自動起動はしない
		)))))))
	      
     ((sumibigpt-kanji (preceding-char))
      (sumibigpt-debug-print (format "sumibigpt-kanji(%s) => t\n" (preceding-char)))
    
      ;; カーソル直前が 全角で漢字以外 だったら候補選択モードに移行する。
      ;; また、最後に確定した文字列と同じかどうかも確認する。
      (when (sumibigpt-history-search (point) t)
	;; 直前に変換したfenceの範囲に入っていたら、候補選択モードに移行する。
	(setq sumibigpt-select-mode t)
	(sumibigpt-debug-print "henkan mode ON\n")
	
	;; 表示状態を候補選択モードに切替える。
	(sumibigpt-display-function
	 (marker-position (car sumibigpt-markers))
	 (marker-position (cdr sumibigpt-markers))
	 t)))

     (t
      (sumibigpt-debug-print (format "<<OTHER:non-ascii,non-kanji>> (%s)\n" (preceding-char))))))))
      


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; キャピタライズ/アンキャピタライズ変換
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun sumibigpt-capitalize-trans ()
  "キャピタライズ変換を行う
・カーソルから行頭方向にローマ字列を見つけ、先頭文字の大文字小文字を反転する"
  (interactive)

  (cond
   (sumibigpt-select-mode
    ;; 候補選択モードでは反応しない。
    ;; do nothing
    )
   ((eq (sumibigpt-char-charset (preceding-char)) 'ascii)
    ;; カーソル直前が alphabet だったら
    (sumibigpt-debug-print "capitalize(2)!\n")

    (let ((end (point))
	  (gap (sumibigpt-skip-chars-backward)))
      (when (/= gap 0)
	;; 意味のある入力が見つかったので変換する
	(let* (
	       (b (+ end gap))
	       (e end)
	       (roman-str (buffer-substring-no-properties b e)))
	  (sumibigpt-debug-print (format "capitalize %d %d [%s]" b e roman-str))
	  (setq case-fold-search nil)
	  (cond
	   ((string-match-p "^[A-Z]" roman-str)
	    (downcase-region b (+ b 1)))
	   ((string-match-p "^[a-z]" roman-str)
	    (upcase-region   b (+ b 1))))))))
   ))


;; 全角で漢字以外の判定関数
(defun sumibigpt-nkanji (ch)
  (and (eq (sumibigpt-char-charset ch) 'japanese-jisx0208)
       (not (string-match "[亜-瑤]" (char-to-string ch)))))

(defun sumibigpt-kanji (ch)
  (eq (sumibigpt-char-charset ch) 'japanese-jisx0208))


;; ローマ字漢字変換時、変換対象とするローマ字を読み飛ばす関数
(defun sumibigpt-skip-chars-backward ()
  (let* (
	 (skip-chars
	  (if auto-fill-function
	      ;; auto-fill-mode が有効になっている場合改行があってもskipを続ける
	      (concat sumibigpt-skip-chars "\n")
	    ;; auto-fill-modeが無効の場合はそのまま
	    sumibigpt-skip-chars))
	    
	 ;; マークされている位置を求める。
	 (pos (or (and (markerp (mark-marker)) (marker-position (mark-marker)))
		  1))

	 ;; 条件にマッチする間、前方方向にスキップする。
	 (result (save-excursion
		   (skip-chars-backward skip-chars (and (< pos (point)) pos))))
	 (limit-point 0))

    (if auto-fill-function
	;; auto-fill-modeが有効の時
	(progn
	  (save-excursion
	    (backward-paragraph)
	    (when (< 1 (point))
	      (forward-line 1))
	    (goto-char (point-at-bol))
	    (let (
		  (start-point (point)))
	      (setq limit-point
		    (+
		     start-point
		     (skip-chars-forward sumibigpt-stop-chars (point-at-eol))))))

	  ;; (sumibigpt-debug-print (format "(point) = %d  result = %d  limit-point = %d\n" (point) result limit-point))
	  ;; (sumibigpt-debug-print (format "a = %d b = %d \n" (+ (point) result) limit-point))

	  ;; パラグラフ位置でストップする
	  (if (< (+ (point) result) limit-point)
	      (- 
	       limit-point
	       (point))
	    result))

      ;; auto-fill-modeが無効の時
      (progn
	(save-excursion
	  (goto-char (point-at-bol))
	  (let (
		(start-point (point)))
	    (setq limit-point
		  (+ 
		   start-point
		   (skip-chars-forward sumibigpt-stop-chars (point-at-eol))))))

	;; (sumibigpt-debug-print (format "(point) = %d  result = %d  limit-point = %d\n" (point) result limit-point))
	;; (sumibigpt-debug-print (format "a = %d b = %d \n" (+ (point) result) limit-point))

	(if (< (+ (point) result) limit-point)
	    ;; インデント位置でストップする。
	    (- 
	     limit-point
	     (point))
	  result)))))


(defun sumibigpt-insert-space (times)
  (if (null times)
      (insert " ")
    (dotimes(i times)
      (insert " "))))

(defun sumibigpt-spacekey-init-function ()
  (define-key global-map (kbd "SPC")
    '(lambda (&optional arg)(interactive "P")
       (cond ((and (< 0 sumibigpt-timer-rest) 
		   sumibigpt-kakutei-with-spacekey)
	      (cond
	       ((string= " " (char-to-string (preceding-char)))
		(sumibigpt-insert-space arg))
	       ((eq       10                 (preceding-char))   ;; 直前に改行があった
		(sumibigpt-insert-space arg))
	       ((string= "/" (char-to-string (preceding-char)))
		(delete-region (- (point) 1) (point))
		(sumibigpt-insert-space arg))
	       (t
		(sumibigpt-rK-trans))))
	     (t
	      (sumibigpt-insert-space arg))))))

;;;
;;; human interface
;;;
(define-key sumibigpt-mode-map sumibigpt-rK-trans-key 'sumibigpt-rK-trans)
(define-key sumibigpt-mode-map "\M-j" 'sumibigpt-capitalize-trans)
(or (assq 'sumibigpt-mode minor-mode-map-alist)
    (setq minor-mode-map-alist
	  (append (list 
		   (cons 'sumibigpt-mode         sumibigpt-mode-map))
		  minor-mode-map-alist)))



;; sumibigpt-mode の状態変更関数
;;  正の引数の場合、常に sumibigpt-mode を開始する
;;  {負,0}の引数の場合、常に sumibigpt-mode を終了する
;;  引数無しの場合、sumibigpt-mode をトグルする

;; buffer 毎に sumibigpt-mode を変更する
(defun sumibigpt-mode (&optional arg)
  "SumibiGPT mode は ローマ字から直接漢字変換するための minor mode です。
引数に正数を指定した場合は、SumibiGPT mode を有効にします。

SumibiGPT モードが有効になっている場合 \\<sumibigpt-mode-map>\\[sumibigpt-rK-trans] で
point から行頭方向に同種の文字列が続く間を漢字変換します。

同種の文字列とは以下のものを指します。
・半角カタカナとsumibigpt-stop-chars に指定した文字を除く半角文字
・漢字を除く全角文字"
  (interactive "P")
  (sumibigpt-mode-internal arg nil))

;; 全バッファで sumibigpt-mode を変更する
(defun global-sumibigpt-mode (&optional arg)
  "SumibiGPT mode は ローマ字から直接漢字変換するための minor mode です。
引数に正数を指定した場合は、SumibiGPT mode を有効にします。

SumibiGPT モードが有効になっている場合 \\<sumibigpt-mode-map>\\[sumibigpt-rK-trans] で
point から行頭方向に同種の文字列が続く間を漢字変換します。

同種の文字列とは以下のものを指します。
・半角カタカナとsumibigpt-stop-chars に指定した文字を除く半角文字
・漢字を除く全角文字"
  (interactive "P")
  (sumibigpt-mode-internal arg t))


;; sumibigpt-mode を変更する共通関数
(defun sumibigpt-mode-internal (arg global)
  (sumibigpt-debug-print "sumibigpt-mode-internal :1\n")

  (or (local-variable-p 'sumibigpt-mode (current-buffer))
      (make-local-variable 'sumibigpt-mode))
  (if global
      (progn
	(setq-default sumibigpt-mode (if (null arg) (not sumibigpt-mode)
				    (> (prefix-numeric-value arg) 0)))
	(sumibigpt-kill-sumibigpt-mode))
    (setq sumibigpt-mode (if (null arg) (not sumibigpt-mode)
			(> (prefix-numeric-value arg) 0))))
  (add-hook 'sumibigpt-mode-hook 'sumibigpt-spacekey-init-function)
  (when sumibigpt-mode (run-hooks 'sumibigpt-mode-hook))

  (sumibigpt-debug-print "sumibigpt-mode-internal :2\n"))


;; buffer local な sumibigpt-mode を削除する関数
(defun sumibigpt-kill-sumibigpt-mode ()
  (let ((buf (buffer-list)))
    (while buf
      (set-buffer (car buf))
      (kill-local-variable 'sumibigpt-mode)
      (setq buf (cdr buf)))))


;; 全バッファで sumibigpt-input-mode を変更する
(defun sumibigpt-input-mode (&optional arg)
  "入力モード変更"
  (interactive "P")
  (if (< 0 arg)
      (progn
	(setq inactivate-current-input-method-function 'sumibigpt-inactivate)
	(setq sumibigpt-mode t))
    (setq inactivate-current-input-method-function nil)
    (setq sumibigpt-mode nil)))


;; input method 対応
(defun sumibigpt-activate (&rest arg)
  (sumibigpt-input-mode 1))
(defun sumibigpt-inactivate (&rest arg)
  (sumibigpt-input-mode -1))
(register-input-method
 "japanese-sumibigpt" "Japanese" 'sumibigpt-activate
 "" "Roman -> Kanji&Kana"
 nil)

;; input-method として登録する。
(set-language-info "Japanese" 'input-method "japanese-sumibigpt")
(setq default-input-method "japanese-sumibigpt")

(defconst sumibigpt-version
  "1.0.0" ;;SUMIBIGPT-VERSION
  )
(defun sumibigpt-version (&optional arg)
  "入力モード変更"
  (interactive "P")
  (message sumibigpt-version))

(provide 'sumibigpt)

;; Local Variables:
;; coding: utf-8
;; End:

;;; sumibigpt.el ends here