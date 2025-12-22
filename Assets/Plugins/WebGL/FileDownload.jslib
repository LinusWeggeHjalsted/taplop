mergeInto(LibraryManager.library, {
    DownloadFile: function(filenamePtr, contentPtr) {
        var filename = UTF8ToString(filenamePtr);
        var content = UTF8ToString(contentPtr);

        var blob = new Blob([content], { type: 'text/plain' });
        var url = URL.createObjectURL(blob);

        var link = document.createElement('a');
        link.href = url;
        link.download = filename;
        link.style.display = 'none';

        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);

        URL.revokeObjectURL(url);
    },

    UploadFile: function(gameObjectNamePtr, callbackMethodNamePtr) {
        var gameObjectName = UTF8ToString(gameObjectNamePtr);
        var callbackMethodName = UTF8ToString(callbackMethodNamePtr);

        var input = document.createElement('input');
        input.type = 'file';
        input.accept = '.txt';
        input.style.display = 'none';

        input.onchange = function(event) {
            var file = event.target.files[0];
            if (file) {
                var reader = new FileReader();
                reader.onload = function(e) {
                    var content = e.target.result;
                    SendMessage(gameObjectName, callbackMethodName, content);
                };
                reader.readAsText(file);
            }
            document.body.removeChild(input);
        };

        input.oncancel = function() {
            document.body.removeChild(input);
        };

        document.body.appendChild(input);
        input.click();
    }
});
