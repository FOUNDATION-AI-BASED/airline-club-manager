$( document ).ready(function() {
    $('input#airlineName').on('input', function() {
        var airlineName = $(this).val()
        $.ajax({
    		type: 'GET',
    		url: "signup/airline-name-check?airlineName=" + airlineName,
    	    contentType: 'application/json; charset=utf-8',
    	    dataType: 'json',
    	    success: function(result) {
    	    	if (result.ok) {
                    $('.airlineName dd.error').text('')
    	    	} else {
    	    	    $('.airlineName dd.error').text(result.rejection)
    	    	}
    	    },
            error: function(jqXHR, textStatus, errorThrown) {
    	            console.log(JSON.stringify(jqXHR));
    	            console.log("AJAX error: " + textStatus + ' : ' + errorThrown);
    	    }
    	});
    })
})

window.signup = function(form) {
    $('body .loadingSpinner').show();
    form.submit();
}

	