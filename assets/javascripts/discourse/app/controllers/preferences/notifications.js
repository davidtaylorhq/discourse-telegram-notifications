<script type="text/discourse-plugin" version="0.8">
  api.modifyClass('controller:preferences:notifications', {
    init: function() {
	this.saveAttrNames.push("custom_fields");
	}
});
</script>
