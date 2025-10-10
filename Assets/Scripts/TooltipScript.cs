using UnityEngine;
using UnityEngine.UI;
using UnityEngine.InputSystem;
using TMPro;

public class TooltipScript : MonoBehaviour
{
    public TMP_Text tooltipHeader;
    public TMP_Text tooltipContent;

    public void SetText(string headerText, string contentText)
    {
        tooltipHeader.text = headerText;
        tooltipContent.text = contentText;
    }

    void Start()
    {
        tooltipHeader = this.transform.Find("Tooltip Header").gameObject.GetComponent<TMP_Text>();
        tooltipContent = this.transform.Find("Tooltip Content").gameObject.GetComponent<TMP_Text>();
    }
}
