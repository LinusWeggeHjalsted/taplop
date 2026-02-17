using UnityEngine;
using UnityEngine.UI;
using UnityEngine.InputSystem;
using TMPro;
using System.Collections;
using System.Text.RegularExpressions;

public class TooltipScript : MonoBehaviour
{
    public bool finishedBuilding = false;
    public TMP_Text tooltipHeader;
    public TMP_Text tooltipContent;
    public LayoutElement layoutElement;
    public int charLimit;

    public IEnumerator SetText(string headerText, string contentText)
    {
        while (!finishedBuilding)
        {
            yield return null;
        }
        string[] splitContent = contentText.Split('\n');
        int maxWidth = 0;
        foreach (string line in splitContent)
        {
            // Strip rich text tags for length calculation
            string strippedLine = Regex.Replace(line, "<.*?>", "");
            if (strippedLine.Length > maxWidth)
            {
                maxWidth = strippedLine.Length;
            }
        }
        if (maxWidth >= charLimit)
        {
            // long text: enable layout element and set max width to force wrapping
            layoutElement.enabled = true;
            layoutElement.preferredWidth = charLimit * 24; // approximate pixels per char
        }
        else
        {
            // short text: disable layout element to let it size naturally
            layoutElement.enabled = false;
        }
        tooltipHeader.text = headerText;
        tooltipContent.text = contentText;
        this.gameObject.SetActive(true);
    }

    void Awake()
    {
        this.gameObject.SetActive(false);
        tooltipHeader = this.transform.Find("Tooltip Header").gameObject.GetComponent<TMP_Text>();
        tooltipContent = this.transform.Find("Tooltip Content").gameObject.GetComponent<TMP_Text>();
        layoutElement = this.GetComponent<LayoutElement>();
        charLimit = 20;
        finishedBuilding = true;
    }
}
