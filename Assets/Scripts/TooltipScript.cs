using UnityEngine;
using UnityEngine.UI;
using UnityEngine.InputSystem;
using TMPro;

public class TooltipScript : MonoBehaviour
{
    public TMP_Text tooltipHeader;
    public TMP_Text tooltipContent;
    public LayoutElement layoutElement;
    public int characterWrapLimit;

    public void SetText(string headerText, string contentText)
    {
        tooltipHeader.text = headerText;
        tooltipContent.text = contentText;
    }

    void Start()
    {
        tooltipHeader = this.transform.Find("Tooltip Header").gameObject.GetComponent<TMP_Text>();
        tooltipContent = this.transform.Find("Tooltip Content").gameObject.GetComponent<TMP_Text>();
        layoutElement = this.GetComponent<LayoutElement>();
        characterWrapLimit = 16;
    }

    void Update()
    {
        int headerLength = tooltipHeader.text.Length;
        int contentLength = tooltipContent.text.Length;
        if (headerLength > characterWrapLimit || contentLength > characterWrapLimit)
        {
            layoutElement.enabled = true;
        }
        else
        {
            layoutElement.enabled = false;
        }
        Vector2 mousePosition = Mouse.current.position.ReadValue();
        this.gameObject.transform.position = mousePosition + new Vector2(0, 128f);
    }
}
