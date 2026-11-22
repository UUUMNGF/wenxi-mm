package gopeed

// LAN file shares (SMB/FTP) reuse the tokenized loopback HTTP pattern of BT
// playback. App-level failures travel inside the JSON payload: both bridges
// replace native error text with a generic message, so error details must
// never travel through the error return.
import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"path"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	smb2 "github.com/cloudsoda/go-smb2"
	"github.com/jlaffaye/ftp"
)

const lanShareDialTimeout = 10 * time.Second

var lanShareMu sync.Mutex
var lanShares = map[string]*lanShareStream{}

type lanShareServer struct {
	ID        string `json:"id"`
	Kind      string `json:"kind"`
	Host      string `json:"host"`
	Port      int    `json:"port"`
	Domain    string `json:"domain"`
	Username  string `json:"username"`
	Password  string `json:"password"`
	Anonymous bool   `json:"anonymous"`
	Share     string `json:"share"`
	Path      string `json:"path"`
}

func (s *lanShareServer) address() string {
	port := s.Port
	if port <= 0 {
		port = map[string]int{"smb": 445, "ftp": 21}[s.Kind]
	}
	return net.JoinHostPort(s.Host, strconv.Itoa(port))
}

// SMB tree paths use backslashes; the app always speaks forward slashes.
func (s *lanShareServer) smbPath() string {
	cleaned := strings.Trim(s.Path, "/\\")
	if cleaned == "" {
		return "\\"
	}
	return strings.ReplaceAll(cleaned, "/", "\\")
}

func (s *lanShareServer) ftpPath() string {
	return "/" + strings.Trim(s.Path, "/")
}

func parseLanShare(value string) (*lanShareServer, error) {
	var input lanShareServer
	if err := json.Unmarshal([]byte(value), &input); err != nil {
		return nil, errors.New("请求格式错误")
	}
	if input.Kind != "smb" && input.Kind != "ftp" {
		return nil, errors.New("仅支持 SMB 与 FTP 共享")
	}
	input.Host = strings.TrimSpace(input.Host)
	if input.Host == "" {
		return nil, errors.New("请填写服务器地址")
	}
	if input.Port < 0 || input.Port > 65535 {
		return nil, errors.New("端口无效")
	}
	input.Share = strings.Trim(input.Share, "/\\")
	return &input, nil
}

func lanSharePayload(payload map[string]any) string {
	value, _ := json.Marshal(payload)
	return string(value)
}

func lanShareFailure(err error) string {
	return lanSharePayload(map[string]any{"ok": false, "error": err.Error()})
}

func lanShareSuccess(payload map[string]any) string {
	base := map[string]any{"ok": true}
	for key, value := range payload {
		base[key] = value
	}
	return lanSharePayload(base)
}

type lanShareEntry struct {
	Name     string `json:"name"`
	Dir      bool   `json:"dir"`
	Size     int64  `json:"size"`
	Modified int64  `json:"modified"`
}

// LanShareProbe verifies credentials and, for SMB, lists the server's share
// names so the edit form can offer a picker.
func LanShareProbe(value string) (string, error) {
	server, err := parseLanShare(value)
	if err != nil {
		return lanShareFailure(err), nil
	}
	if server.Kind == "ftp" {
		conn, err := lanFtpConnect(server)
		if err != nil {
			return lanShareFailure(err), nil
		}
		conn.Quit()
		return lanShareSuccess(map[string]any{"shares": []string{}}), nil
	}
	session, err := lanSmbSession(server)
	if err != nil {
		return lanShareFailure(err), nil
	}
	defer session.Logoff()
	shares, err := session.ListSharenames()
	if err != nil {
		return lanShareFailure(lanShareAccess(err)), nil
	}
	sort.Strings(shares)
	if server.Share != "" {
		share, err := session.Mount(server.Share)
		if err != nil {
			return lanShareFailure(lanShareAccess(err)), nil
		}
		if _, err = share.Stat("\\"); err != nil {
			return lanShareFailure(lanShareAccess(err)), nil
		}
	}
	return lanShareSuccess(map[string]any{"shares": shares}), nil
}

// LanShareList returns one directory level, folders first.
func LanShareList(value string) (string, error) {
	server, err := parseLanShare(value)
	if err != nil {
		return lanShareFailure(err), nil
	}
	var entries []lanShareEntry
	if server.Kind == "ftp" {
		conn, err := lanFtpConnect(server)
		if err != nil {
			return lanShareFailure(err), nil
		}
		defer conn.Quit()
		items, err := conn.List(server.ftpPath())
		if err != nil {
			return lanShareFailure(lanShareAccess(err)), nil
		}
		for _, item := range items {
			if item.Type == ftp.EntryTypeFolder && (item.Name == "." || item.Name == "..") {
				continue
			}
			entries = append(entries, lanShareEntry{
				Name: item.Name, Dir: item.Type == ftp.EntryTypeFolder,
				Size: int64(item.Size), Modified: item.Time.UnixMilli(),
			})
		}
	} else {
		if server.Share == "" {
			return lanShareFailure(errors.New("请选择共享文件夹")), nil
		}
		session, err := lanSmbSession(server)
		if err != nil {
			return lanShareFailure(err), nil
		}
		defer session.Logoff()
		share, err := session.Mount(server.Share)
		if err != nil {
			return lanShareFailure(lanShareAccess(err)), nil
		}
		items, err := share.ReadDir(server.smbPath())
		if err != nil {
			return lanShareFailure(lanShareAccess(err)), nil
		}
		for _, item := range items {
			entries = append(entries, lanShareEntry{
				Name: item.Name(), Dir: item.IsDir(),
				Size: item.Size(), Modified: item.ModTime().UnixMilli(),
			})
		}
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Dir != entries[j].Dir {
			return entries[i].Dir
		}
		return strings.ToLower(entries[i].Name) < strings.ToLower(entries[j].Name)
	})
	return lanShareSuccess(map[string]any{"entries": entries}), nil
}

func lanSmbSession(server *lanShareServer) (*smb2.Session, error) {
	// The context only bounds negotiation and authentication; the returned
	// session outlives it and streams without deadlines.
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	dialer := &smb2.Dialer{
		Initiator: &smb2.NTLMInitiator{
			User: server.Username, Password: server.Password, Domain: server.Domain,
		},
	}
	session, err := dialer.Dial(ctx, server.address())
	if err != nil {
		if isLanSmbAuthError(err) {
			return nil, lanShareAuth(err)
		}
		return nil, lanShareNetwork(err, server)
	}
	return session, nil
}

// NTSTATUS codes from MS-ERREF; the fork keeps them in an internal package.
const (
	ntStatusAccessDenied       = 0xC0000022
	ntStatusNoSuchUser         = 0xC0000064
	ntStatusWrongPassword      = 0xC000006A
	ntStatusLogonFailure       = 0xC000006D
	ntStatusAccountRestriction = 0xC000006E
	ntStatusInvalidLogonHours  = 0xC000006F
	ntStatusInvalidWorkstation = 0xC0000070
	ntStatusPasswordExpired    = 0xC0000071
	ntStatusAccountDisabled    = 0xC0000072
	ntStatusAccountLockedOut   = 0xC0000234
)

func isLanSmbAuthError(err error) bool {
	var response *smb2.ResponseError
	if errors.As(err, &response) {
		switch response.Code {
		case ntStatusAccessDenied, ntStatusNoSuchUser, ntStatusWrongPassword, ntStatusLogonFailure,
			ntStatusAccountRestriction, ntStatusInvalidLogonHours, ntStatusInvalidWorkstation,
			ntStatusPasswordExpired, ntStatusAccountDisabled, ntStatusAccountLockedOut:
			return true
		}
	}
	return false
}

func lanFtpConnect(server *lanShareServer) (*ftp.ServerConn, error) {
	conn, err := ftp.Dial(server.address(), ftp.DialWithTimeout(lanShareDialTimeout))
	if err != nil {
		return nil, lanShareNetwork(err, server)
	}
	if err = conn.Login(server.Username, server.Password); err != nil {
		conn.Quit()
		return nil, lanShareAuth(err)
	}
	return conn, nil
}

func lanShareNetwork(err error, server *lanShareServer) error {
	return &lanShareError{"无法连接到 " + server.address() + "，请检查地址与网络"}
}

func lanShareAuth(err error) error {
	return &lanShareError{"登录失败，请检查用户名、密码或服务器的访问权限"}
}

func lanShareAccess(err error) error {
	return &lanShareError{"无法访问共享内容，请检查路径与共享权限"}
}

type lanShareError struct {
	message string
}

func (e *lanShareError) Error() string { return e.message }

// LanShareStreamStart opens a loopback HTTP server serving one remote file
// with range support, so the media player can seek without buffering it all.
func LanShareStreamStart(value string) (string, error) {
	server, err := parseLanShare(value)
	if err != nil {
		return lanShareFailure(err), nil
	}
	if !safeID.MatchString(server.ID) {
		return lanShareFailure(errors.New("无效的播放请求")), nil
	}
	name, size, session, share, conn, err := lanShareOpenFile(server)
	if err != nil {
		return lanShareFailure(err), nil
	}
	lanShareMu.Lock()
	if old := lanShares[server.ID]; old != nil {
		delete(lanShares, server.ID)
		go old.close()
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &lanShareStream{
		id: server.ID, smbRemote: server.smbPath(), remotePath: server.ftpPath(), name: name, size: size,
		config: *server, session: session, share: share, conn: conn,
		ctx: ctx, cancel: cancel,
		etag:          `"` + server.ID + "-" + strconv.FormatInt(size, 10) + `"`,
		activeReaders: make(map[uint64]context.CancelFunc),
	}
	ready := false
	defer func() {
		if !ready {
			go s.close()
		}
	}()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		lanShareMu.Unlock()
		go s.close()
		return lanShareFailure(errors.New("无法启动本地播放连接")), nil
	}
	var token [24]byte
	if _, err = rand.Read(token[:]); err != nil {
		lanShareMu.Unlock()
		go s.close()
		return lanShareFailure(errors.New("无法初始化本地播放地址")), nil
	}
	s.path = "/" + hex.EncodeToString(token[:]) + "/" + url.PathEscape(name)
	s.uri = "http://" + listener.Addr().String() + s.path
	s.server = &http.Server{
		Handler: http.HandlerFunc(s.serve), ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8 * 1024,
	}
	lanShares[server.ID] = s
	go s.server.Serve(listener)
	lanShareMu.Unlock()
	ready = true
	return lanShareSuccess(map[string]any{"id": server.ID, "url": s.uri, "size": size, "name": name}), nil
}

// lanShareOpenFile authenticates and stats the target file, keeping the
// session alive for the stream. Exactly one of share/conn is non-nil.
func lanShareOpenFile(server *lanShareServer) (name string, size int64, session *smb2.Session, share *smb2.Share, conn *ftp.ServerConn, err error) {
	if server.Kind == "ftp" {
		conn, err = lanFtpConnect(server)
		if err != nil {
			return "", 0, nil, nil, nil, err
		}
		entry, statErr := conn.GetEntry(server.ftpPath())
		if statErr != nil || entry.Type == ftp.EntryTypeFolder {
			conn.Quit()
			return "", 0, nil, nil, nil, lanShareAccess(statErr)
		}
		return entry.Name, int64(entry.Size), nil, nil, conn, nil
	}
	if server.Share == "" {
		return "", 0, nil, nil, nil, errors.New("请选择共享文件夹")
	}
	session, err = lanSmbSession(server)
	if err != nil {
		return "", 0, nil, nil, nil, err
	}
	share, err = session.Mount(server.Share)
	if err != nil {
		session.Logoff()
		return "", 0, nil, nil, nil, lanShareAccess(err)
	}
	info, statErr := share.Stat(server.smbPath())
	if statErr != nil || info.IsDir() {
		share.Umount()
		session.Logoff()
		return "", 0, nil, nil, nil, lanShareAccess(statErr)
	}
	return info.Name(), info.Size(), session, share, nil, nil
}

// LanShareStreamStop closes a stream and its remote session.
func LanShareStreamStop(id string) (string, error) {
	lanShareMu.Lock()
	s := lanShares[id]
	if s != nil {
		delete(lanShares, id)
	}
	lanShareMu.Unlock()
	if s != nil {
		s.close()
	}
	return lanShareSuccess(map[string]any{"id": id}), nil
}

func closeLanShares() {
	lanShareMu.Lock()
	sessions := lanShares
	lanShares = map[string]*lanShareStream{}
	lanShareMu.Unlock()
	for _, s := range sessions {
		s.close()
	}
}

type lanShareStream struct {
	id, smbRemote, remotePath, name, etag, path, uri string
	size                                             int64
	config                                           lanShareServer
	// SMB keeps one authenticated session and one mounted share across
	// requests; FTP keeps one logged-in control connection. Requests never
	// reuse file handles: each one opens and closes its own.
	session *smb2.Session
	share   *smb2.Share
	conn    *ftp.ServerConn

	server          *http.Server
	cancel          context.CancelFunc
	ctx             context.Context
	requests        sync.WaitGroup
	requestMu       sync.Mutex
	activeReaders   map[uint64]context.CancelFunc
	requestSequence uint64
	closed          bool
}

func (s *lanShareStream) serve(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != s.path {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if strings.Contains(r.Header.Get("Range"), ",") {
		http.Error(w, "one range per request", http.StatusRequestedRangeNotSatisfiable)
		return
	}
	ctx, cancel := context.WithCancel(s.ctx)
	stop := context.AfterFunc(r.Context(), cancel)
	defer stop()
	defer cancel()
	s.requestMu.Lock()
	if s.closed {
		s.requestMu.Unlock()
		http.Error(w, "playback closed", http.StatusGone)
		return
	}
	var requestID uint64
	if r.Method == http.MethodGet {
		// Demuxers read header, index and media concurrently; only an explicit
		// seek/disposal interrupts them.
		if len(s.activeReaders) >= streamMaxReaders {
			s.requestMu.Unlock()
			http.Error(w, "too many media readers", http.StatusTooManyRequests)
			return
		}
		s.requestSequence++
		requestID = s.requestSequence
		s.activeReaders[requestID] = cancel
	}
	s.requests.Add(1)
	s.requestMu.Unlock()
	defer s.requests.Done()
	if requestID != 0 {
		defer func() {
			s.requestMu.Lock()
			delete(s.activeReaders, requestID)
			s.requestMu.Unlock()
		}()
	}
	reader, err := s.openReader()
	if err != nil {
		http.Error(w, "share unavailable", http.StatusBadGateway)
		return
	}
	defer reader.Close()
	contentType := mime.TypeByExtension(path.Ext(strings.ToLower(s.name)))
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("ETag", s.etag)
	w.Header().Set("Cache-Control", "private, no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r.WithContext(ctx), s.name, time.Time{}, reader)
}

// openReader returns one positioned, closable reader per request.
type lanShareReader interface {
	io.ReadSeeker
	Close() error
}

func (s *lanShareStream) openReader() (lanShareReader, error) {
	if s.config.Kind == "ftp" {
		return &lanFtpReader{conn: s.conn, remote: s.smbRemote, size: s.size}, nil
	}
	file, err := s.share.Open(s.smbRemote)
	if err != nil {
		// A lost session (server reboot, sleep) is re-established transparently;
		// every request opens a fresh handle so the player keeps its position.
		if refreshErr := s.refreshSmb(); refreshErr == nil {
			file, err = s.share.Open(s.smbRemote)
		}
	}
	if err != nil {
		return nil, err
	}
	return file, nil
}

func (s *lanShareStream) refreshSmb() error {
	oldSession, oldShare := s.session, s.share
	session, err := lanSmbSession(&s.config)
	if err != nil {
		return err
	}
	share, err := session.Mount(s.config.Share)
	if err != nil {
		session.Logoff()
		return err
	}
	s.session, s.share = session, share
	if oldShare != nil {
		oldShare.Umount()
	}
	if oldSession != nil {
		oldSession.Logoff()
	}
	return nil
}

func (s *lanShareStream) close() {
	s.requestMu.Lock()
	alreadyClosed := s.closed
	s.closed = true
	s.cancel()
	s.requestMu.Unlock()
	if alreadyClosed {
		return
	}
	if s.server != nil {
		s.server.Close()
	}
	// A media read stuck on a dead share must not block app shutdown; the
	// handler goroutine is abandoned with its session instead.
	done := make(chan struct{})
	go func() {
		s.requests.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
	}
	if s.share != nil {
		s.share.Umount()
	}
	if s.session != nil {
		s.session.Logoff()
	}
	if s.conn != nil {
		s.conn.Quit()
	}
}

// lanFtpReader is an io.ReadSeeker over RETR ranges. Forward seeks inside the
// open response discard bytes; backward seeks reopen the data connection at
// the target offset through the same control connection.
type lanFtpReader struct {
	conn   *ftp.ServerConn
	remote string
	size   int64
	body   io.ReadCloser
	pos    int64
}

func (r *lanFtpReader) Read(p []byte) (int, error) {
	if r.body == nil {
		return 0, errors.New("ftp reader closed")
	}
	n, err := r.body.Read(p)
	r.pos += int64(n)
	return n, err
}

func (r *lanFtpReader) Seek(offset int64, whence int) (int64, error) {
	switch whence {
	case io.SeekCurrent:
		offset += r.pos
	case io.SeekEnd:
		offset += r.size
	case io.SeekStart:
	default:
		return 0, errors.New("invalid seek whence")
	}
	if offset < 0 || offset > r.size {
		return 0, errors.New("seek out of range")
	}
	if offset == r.pos && r.body != nil {
		return r.pos, nil
	}
	if r.body != nil {
		if offset > r.pos {
			if _, err := io.CopyN(io.Discard, r.body, offset-r.pos); err != nil {
				return 0, err
			}
			return r.pos, nil
		}
		r.body.Close()
		r.body = nil
	}
	response, err := r.conn.RetrFrom(r.remote, uint64(offset))
	if err != nil {
		return 0, err
	}
	r.body, r.pos = response, offset
	return r.pos, nil
}

func (r *lanFtpReader) Close() error {
	if r.body == nil {
		return nil
	}
	err := r.body.Close()
	r.body = nil
	return err
}
