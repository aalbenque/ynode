<?php
// ── Session & cookie ──────────────────────────────────────────────────────
session_start();

// Count page loads across keep-alive requests
$_SESSION['hits'] = ($_SESSION['hits'] ?? 0) + 1;

// Set a test cookie if not already present
if (!isset($_COOKIE['yn_test'])) {
    setcookie('yn_test', bin2hex(random_bytes(4)), time() + 3600, '/');
}

// ── Custom response header (visible in DevTools / curl) ───────────────────
header('X-YNode-Test: ok');
header('X-Session-Hits: ' . $_SESSION['hits']);

// ── POST / file upload handling ───────────────────────────────────────────
$post_result = null;
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['_action'])) {
    switch ($_POST['_action']) {
        case 'form':
            $post_result = [
                'action' => 'form',
                'name'   => htmlspecialchars($_POST['name']  ?? ''),
                'email'  => htmlspecialchars($_POST['email'] ?? ''),
                'file'   => $_FILES['file'] ?? null,
            ];
            break;
        case 'raw':
            $raw  = file_get_contents('php://input');
            $post_result = [
                'action' => 'raw',
                'length' => strlen($raw),
                'body'   => htmlspecialchars(substr($raw, 0, 512)),
            ];
            break;
        case 'json':
            $raw  = file_get_contents('php://input');
            $data = json_decode($raw, true);
            $post_result = [
                'action' => 'json',
                'parsed' => $data,
                'raw'    => htmlspecialchars(substr($raw, 0, 512)),
            ];
            break;
    }
}

// ── Detect raw/JSON fetch (no _action in $_POST) ──────────────────────────
if ($post_result === null && $_SERVER['REQUEST_METHOD'] === 'POST') {
    $ct = $_SERVER['CONTENT_TYPE'] ?? '';
    if (str_starts_with($ct, 'application/json')) {
        $raw  = file_get_contents('php://input');
        $data = json_decode($raw, true);
        $post_result = [
            'action' => 'json',
            'parsed' => $data,
            'raw'    => htmlspecialchars(substr($raw, 0, 512)),
        ];
    } elseif (!str_starts_with($ct, 'multipart/') && !str_starts_with($ct, 'application/x-www-form-urlencoded')) {
        $raw  = file_get_contents('php://input');
        $post_result = [
            'action' => 'raw',
            'length' => strlen($raw),
            'body'   => htmlspecialchars(substr($raw, 0, 512)),
        ];
    }
}

// ── CGI / FastCGI environment ─────────────────────────────────────────────
$cgi_vars = [
    'SERVER_SOFTWARE', 'SERVER_NAME', 'GATEWAY_INTERFACE',
    'SERVER_PROTOCOL', 'SERVER_PORT', 'REQUEST_METHOD',
    'REQUEST_URI', 'SCRIPT_NAME', 'QUERY_STRING',
    'CONTENT_TYPE', 'CONTENT_LENGTH', 'DOCUMENT_ROOT',
    'SCRIPT_FILENAME', 'REMOTE_ADDR', 'HTTP_HOST',
    'HTTP_USER_AGENT', 'HTTP_ACCEPT_ENCODING',
    'HTTP_CONNECTION', 'REDIRECT_STATUS',
];

// ── Interesting $_SERVER keys ─────────────────────────────────────────────
$interesting_headers = [];
foreach ($_SERVER as $k => $v) {
    if (str_starts_with($k, 'HTTP_')) {
        $interesting_headers[$k] = $v;
    }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>YNode/0.1 - PHP Test</title>
  <link rel="icon" href="/favicon.ico">
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" integrity="sha256-PI8n5gCcz9cQqQXm3PEtDuPG8qx9oFsFctPg0S5zb8g=" crossorigin="anonymous">
  <link rel="stylesheet" href="css/ynode.css">
</head>
<body>
<div class="container py-5">
<div class="main-card shadow-lg p-4 p-md-5">

  <!-- ── Hero ─────────────────────────────────────────────────────────── -->
  <div class="hero d-flex align-items-center gap-3 flex-wrap">
    <img src="img/ynode.png" alt="YNode logo">
    <div class="flex-grow-1">
      <h1 class="mb-0 fw-bold">YNode
        <span class="badge bg-secondary badge-server ms-1">0.1</span>
      </h1>
      <p class="text-muted mb-0">
        PHP <?= PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION ?> via FastCGI
        &nbsp;·&nbsp;
        <span class="hit-badge">session hit #<?= $_SESSION['hits'] ?></span>
      </p>
    </div>
    <div class="d-flex gap-2">
      <a href="docs.html" class="btn btn-outline-secondary btn-sm">Docs</a>
      <a href="index.html" class="btn btn-outline-secondary btn-sm">Demo</a>
    </div>
  </div>

  <!-- ── FastCGI / CGI environment ──────────────────────────────────────── -->
  <section class="test-section">
    <h2 class="h5 fw-semibold mb-3">FastCGI environment</h2>
    <p class="text-muted small">
      These are the CGI variables YNode populates via the FastCGI PARAMS record and forwards to PHP-FPM.
    </p>
    <div class="term"><?php
      foreach ($cgi_vars as $k):
        $v = $_SERVER[$k] ?? null;
        if ($v !== null):
          echo '<span class="k">' . str_pad($k, 24) . '</span>  <span class="v">' . htmlspecialchars($v) . "</span>\n";
        else:
          echo '<span class="k">' . str_pad($k, 24) . '</span>  <span style="color:#585b70">-</span>' . "\n";
        endif;
      endforeach;
    ?></div>

    <h3>Incoming HTTP headers</h3>
    <div class="term"><?php
      foreach ($interesting_headers as $k => $v):
        echo '<span class="k">' . str_pad($k, 28) . '</span>  <span class="v">' . htmlspecialchars($v) . "</span>\n";
      endforeach;
      if (empty($interesting_headers)) echo '<span style="color:#585b70">(none)</span>';
    ?></div>
  </section>

  <!-- ── Session & cookies ──────────────────────────────────────────────── -->
  <section class="test-section">
    <h2 class="h5 fw-semibold mb-3">Session &amp; cookies</h2>
    <div class="row g-3">
      <div class="col-md-6">
        <h3>$_SESSION</h3>
        <div class="term"><?php
          foreach ($_SESSION as $k => $v):
            echo '<span class="k">' . htmlspecialchars($k) . '</span>  <span class="v">' . htmlspecialchars(var_export($v, true)) . "</span>\n";
          endforeach;
        ?></div>
      </div>
      <div class="col-md-6">
        <h3>$_COOKIE</h3>
        <div class="term"><?php
          foreach ($_COOKIE as $k => $v):
            echo '<span class="k">' . htmlspecialchars($k) . '</span>  <span class="v">' . htmlspecialchars($v) . "</span>\n";
          endforeach;
          if (empty($_COOKIE)) echo '<span style="color:#585b70">(none yet - reload)</span>';
        ?></div>
      </div>
    </div>
  </section>

  <!-- ── POST / upload form ─────────────────────────────────────────────── -->
  <section class="test-section">
    <h2 class="h5 fw-semibold mb-3">POST &amp; file upload</h2>
<?php if ($post_result): ?>
    <div class="alert alert-success py-2 small mb-3">
      <strong>POST received</strong>
      (action: <code><?= $post_result['action'] ?></code>)
      - <a href="/index.php" class="alert-link">clear</a>
    </div>
    <div class="term"><?php
      switch ($post_result['action']):
        case 'form':
          echo '<span class="k">name </span>  <span class="v">' . $post_result['name']  . "</span>\n";
          echo '<span class="k">email</span>  <span class="v">' . $post_result['email'] . "</span>\n";
          if ($post_result['file'] && $post_result['file']['error'] === UPLOAD_ERR_OK):
            $f = $post_result['file'];
            echo '<span class="k">file </span>  <span class="v">' . htmlspecialchars($f['name']) . ' (' . number_format($f['size']) . ' bytes, ' . htmlspecialchars($f['type']) . ")</span>\n";
          elseif ($post_result['file']):
            echo '<span class="k">file </span>  <span class="er">upload error ' . $post_result['file']['error'] . "</span>\n";
          endif;
          break;
        case 'raw':
          echo '<span class="k">Content-Length</span>  <span class="v">' . $post_result['length'] . "</span>\n";
          echo '<span class="k">Body (first 512)</span>\n<span class="hi">' . $post_result['body'] . "</span>\n";
          break;
        case 'json':
          echo '<span class="k">Parsed JSON</span>\n<span class="v">' . htmlspecialchars(json_encode($post_result['parsed'], JSON_PRETTY_PRINT)) . "</span>\n";
          break;
      endswitch;
    ?></div>
<?php endif; ?>

    <div class="row g-4">
      <!-- multipart/form-data -->
      <div class="col-lg-4">
        <div class="card border-0 bg-light h-100">
          <div class="card-body">
            <h6 class="card-title fw-semibold">multipart/form-data</h6>
            <p class="text-muted small mb-3">Standard HTML form with optional file upload.</p>
            <form method="POST" enctype="multipart/form-data">
              <input type="hidden" name="_action" value="form">
              <div class="mb-2">
                <input class="form-control form-control-sm" type="text" name="name" placeholder="Name">
              </div>
              <div class="mb-2">
                <input class="form-control form-control-sm" type="email" name="email" placeholder="Email">
              </div>
              <div class="mb-3">
                <input class="form-control form-control-sm" type="file" name="file">
              </div>
              <button class="btn btn-primary btn-sm w-100" type="submit">Send</button>
            </form>
          </div>
        </div>
      </div>

      <!-- raw body -->
      <div class="col-lg-4">
        <div class="card border-0 bg-light h-100">
          <div class="card-body">
            <h6 class="card-title fw-semibold">Raw request body</h6>
            <p class="text-muted small mb-3">Sends an arbitrary body and echoes its length.</p>
            <textarea class="form-control form-control-sm font-monospace mb-2"
                      id="raw-body" rows="5"
                      placeholder="hello world&#10;any bytes go here">hello from YNode</textarea>
            <button class="btn btn-primary btn-sm w-100" id="btn-raw">Send raw POST</button>
          </div>
        </div>
      </div>

      <!-- JSON -->
      <div class="col-lg-4">
        <div class="card border-0 bg-light h-100">
          <div class="card-body">
            <h6 class="card-title fw-semibold">JSON body</h6>
            <p class="text-muted small mb-3">Posts <code>application/json</code> and shows parsed output.</p>
            <textarea class="form-control form-control-sm font-monospace mb-2"
                      id="json-body" rows="5"
                      placeholder='{"key":"value"}'>{
  "server": "YNode",
  "test": true,
  "n": 42
}</textarea>
            <button class="btn btn-primary btn-sm w-100" id="btn-json">Send JSON POST</button>
          </div>
        </div>
      </div>
    </div>
  </section>

  <!-- ── Custom response code ────────────────────────────────────────────── -->
  <section class="test-section">
    <h2 class="h5 fw-semibold mb-3">Custom response codes</h2>
    <p class="text-muted small">
      Each link fetches a PHP endpoint via <code>fetch()</code> and shows the returned status code.
      <code>test.php</code> always returns <code>201</code>; <code>test_fcgi.php</code> echoes the raw POST body.
    </p>
    <div class="d-flex flex-wrap gap-2 mb-3">
      <button class="btn btn-outline-secondary btn-sm font-monospace" data-fetch="/test.php" data-method="GET">/test.php → 201</button>
      <button class="btn btn-outline-secondary btn-sm font-monospace" data-fetch="/test_fcgi.php" data-method="GET">/test_fcgi.php</button>
      <button class="btn btn-outline-secondary btn-sm font-monospace" data-fetch="/ping" data-method="GET">/ping → 200</button>
      <button class="btn btn-outline-secondary btn-sm font-monospace" data-fetch="/restricted" data-method="GET">/restricted → 401</button>
      <button class="btn btn-outline-secondary btn-sm font-monospace" data-fetch="/.ynaccess" data-method="GET">/.ynaccess → 404</button>
      <button class="btn btn-outline-secondary btn-sm font-monospace" data-fetch="/phpinfo.php" data-method="GET">/phpinfo.php → 403</button>
    </div>
    <div class="term" id="fetch-out" style="min-height:4rem">- click a button to fire a request -</div>
  </section>

  <!-- ── PHP info grid ──────────────────────────────────────────────────── -->
  <section class="test-section">
    <h2 class="h5 fw-semibold mb-3">PHP runtime info</h2>
    <div class="row g-3">
      <?php
      $checks = [
        'PHP version'          => PHP_VERSION,
        'SAPI'                 => PHP_SAPI,
        'Max upload size'      => ini_get('upload_max_filesize'),
        'Max POST size'        => ini_get('post_max_size'),
        'Memory limit'         => ini_get('memory_limit'),
        'Session save handler' => ini_get('session.save_handler'),
        'Session ID'           => session_id(),
        'Opcache'              => extension_loaded('Zend OPcache') ? 'enabled' : 'disabled',
        'Output buffering'     => ini_get('output_buffering') ?: 'off',
        'zlib'                 => extension_loaded('zlib') ? phpversion('zlib') : 'not loaded',
      ];
      foreach ($checks as $label => $value):
      ?>
      <div class="col-sm-6 col-lg-4">
        <div class="d-flex justify-content-between align-items-baseline px-2 py-1"
             style="border-bottom:1px solid #f0f1f3; font-size:.85rem">
          <span class="text-muted"><?= $label ?></span>
          <code><?= htmlspecialchars($value) ?></code>
        </div>
      </div>
      <?php endforeach; ?>
    </div>
  </section>

</div><!-- /.main-card -->
<footer class="text-center mt-4">
  YNode/0.1 &nbsp;·&nbsp; BSD 3-Clause &nbsp;·&nbsp;
  <a href="https://github.com/aalbenque/ynode" class="text-white-50">GitHub</a>
</footer>
</div><!-- /.container -->

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.min.js" integrity="sha256-3gQJhtmj7YnV1fmtbVcnAV6eI4ws0Tr48bVZCThtCGQ=" crossorigin="anonymous"></script>
<script src="js/php.js"></script>
</body>
</html>
