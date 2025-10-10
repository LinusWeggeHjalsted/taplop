using UnityEngine;
using UnityEngine.UI;
using UnityEngine.InputSystem;
using TMPro;
using System.Collections;

public class TooltipScript : MonoBehaviour
{
    public bool finishedBuilding;
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
            if (line.Length > maxWidth)
            {
                maxWidth = line.Length;
            }
        }
        Debug.Log("maxWidth " + maxWidth + " and charLimit " + charLimit);
        if (maxWidth < charLimit)
        {
            layoutElement.enabled = false;
        }
        tooltipHeader.text = headerText;
        tooltipContent.text = contentText;
        this.gameObject.SetActive(true);
    }

    void Start()
    {
        this.gameObject.SetActive(false);
        tooltipHeader = this.transform.Find("Tooltip Header").gameObject.GetComponent<TMP_Text>();
        tooltipContent = this.transform.Find("Tooltip Content").gameObject.GetComponent<TMP_Text>();
        layoutElement = this.GetComponent<LayoutElement>();
        charLimit = 32;
        finishedBuilding = true;
    }
}
