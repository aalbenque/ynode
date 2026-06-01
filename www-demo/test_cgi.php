<?php
$body = file_get_contents("php://input");
header("Content-Type: text/html");
echo "len=" . strlen($body) . "\n";
echo "body=" . $body . "\n";

http_response_code(201);
echo "<h1>OK</h1>";
