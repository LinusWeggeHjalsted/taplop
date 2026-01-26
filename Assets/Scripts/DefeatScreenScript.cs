using UnityEngine;

public class DefeatScreenScript : MonoBehaviour
{
    void Start()
    {
        SoundControllerScript.Instance.PlayDefeatSound();
    }
}
